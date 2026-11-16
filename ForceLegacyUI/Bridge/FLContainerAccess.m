// SPDX-License-Identifier: GPL-3.0-or-later
// Independent, LS-only implementation informed by 3105 / MHA-C2 and bad_query research.
#import "FLContainerAccess.h"
#import "FLContainerRuntime.h"
#import "FLStoreDiscovery.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

BOOL FLHouseArrestIdentityAllowed(NSString *bundleID, NSString *mode) {
    return [bundleID isKindOfClass:NSString.class] && [mode isKindOfClass:NSString.class] &&
        [mode isEqualToString:@"house-arrest"] && [bundleID isEqualToString:@"com.apple.mobile.MobileHouseArrest"];
}
NSString *FLTraversalDomainForCacheDirectory(NSString *directory) {
    directory = FLNormalizeStorePath(directory);
    if (!FLIsAllowedStoreDirectory(directory) && ![FLStoreContainerRoots() containsObject:directory]) return nil;
    NSMutableArray *parents = [NSMutableArray array];
    for (unsigned depth = 0; depth < 8; ++depth) [parents addObject:@".."];
    return [[parents componentsJoinedByString:@"/"] stringByAppendingString:directory];
}
static BOOL FLReadDirectory(const char *path, int *failure) {
    int descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) { if (failure) *failure = errno; return NO; }
    close(descriptor); if (failure) *failure = 0; return YES;
}
static void *FLSymbol(const char *name, void *manager, void *sandbox, void *framework) {
    void *value = manager ? dlsym(manager, name) : NULL;
    if (!value) value = dlsym(RTLD_DEFAULT, name);
    if (!value && sandbox) value = dlsym(sandbox, name);
    if (!value && framework) value = dlsym(framework, name);
    return value;
}
static FLContainerRuntime *FLContainerFunctions(void) {
    static FLContainerRuntime api; static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *manager = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        void *sandbox = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW | RTLD_LOCAL);
        void *framework = dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_LAZY | RTLD_LOCAL);
#define FL_SYMBOL(field, name) api.field = (__typeof(api.field))FLSymbol(name, manager, sandbox, framework)
        FL_SYMBOL(create, "container_query_create"); FL_SYMBOL(kind, "container_query_set_class");
        FL_SYMBOL(identifiers, "container_query_set_identifiers"); FL_SYMBOL(groups, "container_query_set_group_identifiers");
        FL_SYMBOL(flags, "container_query_operation_set_flags"); FL_SYMBOL(part, "container_query_set_part");
        FL_SYMBOL(domain, "container_query_set_part_domain"); FL_SYMBOL(result, "container_query_get_single_result");
        FL_SYMBOL(path, "container_object_get_path"); FL_SYMBOL(token, "container_copy_sandbox_token");
        FL_SYMBOL(duplicate, "container_object_copy"); FL_SYMBOL(activate, "container_object_sandbox_extension_activate");
        FL_SYMBOL(freeObject, "container_object_free"); FL_SYMBOL(dispose, "container_query_free");
        FL_SYMBOL(failure, "container_query_get_last_error"); FL_SYMBOL(message, "container_error_get_message");
        FL_SYMBOL(posix, "container_error_get_posix_errno"); FL_SYMBOL(consume, "sandbox_extension_consume");
        FL_SYMBOL(release, "sandbox_extension_release");
#undef FL_SYMBOL
        api.readableDirectory = FLReadDirectory;
        // Keep handles loaded while sessions hold copied function tables.
    });
    return &api;
}
static NSArray<NSString *> *FLMissingQuery(FLContainerRuntime *api, BOOL traversal) {
    NSMutableArray *missing = [NSMutableArray array];
#define FL_NEED(field, name) if (!api->field) [missing addObject:@name]
    FL_NEED(create, "container_query_create"); FL_NEED(kind, "container_query_set_class");
    FL_NEED(flags, "container_query_operation_set_flags"); FL_NEED(result, "container_query_get_single_result");
    FL_NEED(dispose, "container_query_free");
    if (traversal) {
        FL_NEED(groups, "container_query_set_group_identifiers"); FL_NEED(part, "container_query_set_part");
        FL_NEED(domain, "container_query_set_part_domain");
    } else { FL_NEED(identifiers, "container_query_set_identifiers"); FL_NEED(path, "container_object_get_path"); }
#undef FL_NEED
    return missing;
}
static NSArray<NSString *> *FLMissingManual(FLContainerRuntime *api) {
    NSMutableArray *missing = [NSMutableArray array];
    if (!api->token) [missing addObject:@"container_copy_sandbox_token"];
    if (!api->consume) [missing addObject:@"sandbox_extension_consume"];
    if (!api->release) [missing addObject:@"sandbox_extension_release"];
    return missing;
}
static NSArray<NSString *> *FLMissingObject(FLContainerRuntime *api) {
    NSMutableArray *missing = [NSMutableArray array];
    if (!api->duplicate) [missing addObject:@"container_object_copy"];
    if (!api->activate) [missing addObject:@"container_object_sandbox_extension_activate"];
    if (!api->freeObject) [missing addObject:@"container_object_free"];
    return missing;
}
static NSString *FLCapability(NSArray *missing) { return missing.count ? [missing componentsJoinedByString:@", "] : @"available"; }
NSString *FLContainerRuntimeDiagnostics(void) {
    FLContainerRuntime *api = FLContainerFunctions();
    return [NSString stringWithFormat:@"MHA lookup symbols: %@.\nMHA object activation symbols: %@.\nManual token symbols: %@.\nTraversal query symbols: %@.\n",
        FLCapability(FLMissingQuery(api, NO)), FLCapability(FLMissingObject(api)),
        FLCapability(FLMissingManual(api)), FLCapability(FLMissingQuery(api, YES))];
}
void FLReleaseDirectoryToken(int64_t token) {
    FLContainerRuntime *api = FLContainerFunctions();
    if (token >= 0 && api->release) api->release(token);
}
BOOL FLCanReleaseDirectoryTokens(void) { return FLContainerFunctions()->release != NULL; }
static void FLLogQueryFailure(FLContainerRuntime *api, void *query, NSMutableString *log) {
    void *failure = api->failure ? api->failure(query) : NULL;
    int code = failure && api->posix ? api->posix(failure) : 0;
    const char *message = failure && api->message ? api->message(failure) : NULL;
    [log appendFormat:@"Container query detail: posix %d; %s.\n", code, message ?: "no detail returned"];
}
int64_t FLTraversalTokenForCacheDirectory(NSString *directory, NSMutableString *log) {
    NSString *domain = FLTraversalDomainForCacheDirectory(directory);
    if (!domain) { [log appendString:@"Traversal fallback refused a path outside LS discovery policy.\n"]; return -100; }
    FLContainerRuntime *api = FLContainerFunctions();
    NSArray *missing = [FLMissingQuery(api, YES) arrayByAddingObjectsFromArray:FLMissingManual(api)];
    if (missing.count) {
        if (![log containsString:@"Traversal fallback missing symbols:"])
            [log appendFormat:@"Traversal fallback missing symbols: %@.\n", FLCapability(missing)];
        return -101;
    }
    void *query = api->create(); if (!query) return -102;
    @try {
        api->kind(query, 13);
        xpc_object_t group = xpc_string_create("systemgroup.com.apple.mobilegestaltcache");
        api->groups(query, group); api->part(query, 3); api->domain(query, domain.UTF8String);
        api->flags(query, 0x8000000000ULL);
        void *object = api->result(query);
        if (!object) { [log appendString:@"Traversal fallback returned no result.\n"]; FLLogQueryFailure(api, query, log); return -103; }
        char *token = api->token(object);
        if (!token) { [log appendString:@"Traversal fallback returned no sandbox token.\n"]; return -104; }
        int64_t handle = api->consume(token); free(token);
        [log appendFormat:@"Traversal fallback %@: handle %lld; directory access still must be checked.\n", directory, (long long)handle];
        return handle;
    } @finally { api->dispose(query); }
}

@interface FLLSDContainerLease () {
    void *_query;
    void *_activation;
    int64_t _token;
    FLContainerRuntime _api;
}
@property (nonatomic, readwrite, copy) NSString *cacheDirectory;
+ (instancetype)openForClass:(uint64_t)kind runtime:(const FLContainerRuntime *)runtime log:(NSMutableString *)log;
@end
@implementation FLLSDContainerLease
- (instancetype)init { if ((self = [super init])) _token = -1; return self; }
+ (instancetype)openForClass:(uint64_t)kind log:(NSMutableString *)log {
    if (!FLHouseArrestIdentityAllowed(NSBundle.mainBundle.bundleIdentifier ?: @"",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"FLAccessMode"] ?: @"")) return nil;
    return [self openForClass:kind runtime:FLContainerFunctions() log:log];
}
+ (instancetype)openForClass:(uint64_t)kind runtime:(const FLContainerRuntime *)runtime log:(NSMutableString *)log {
    if (kind != 10 && kind != 12) return nil;
    FLContainerRuntime api = *runtime;
    NSArray *missing = FLMissingQuery(&api, NO);
    if (missing.count) { [log appendFormat:@"MHA lookup missing symbols: %@.\n", FLCapability(missing)]; return nil; }
    FLLSDContainerLease *lease = [FLLSDContainerLease new]; lease->_api = api;
    lease->_query = api.create(); if (!lease->_query) return nil;
    api.kind(lease->_query, kind);
    xpc_object_t identifier = xpc_string_create("com.apple.lsd");
    api.identifiers(lease->_query, identifier);
    if (api.part) api.part(lease->_query, 0);
    api.flags(lease->_query, 0x900000000ULL);
    void *object = api.result(lease->_query);
    if (!object) {
        [log appendFormat:@"MHA lsd class %llu: no result.\n", (unsigned long long)kind]; FLLogQueryFailure(&api, lease->_query, log); return nil;
    }
    const char *raw = api.path(object);
    NSString *root = raw ? FLNormalizeStorePath([NSString stringWithUTF8String:raw]) : @"";
    NSString *cache = [root stringByAppendingPathComponent:@"Library/Caches"];
    if (!root.length || !FLIsAllowedStoreDirectory(cache)) { [log appendString:@"MHA lsd path outside cache policy.\n"]; return nil; }
    BOOL activated = NO;
    NSArray *objectMissing = FLMissingObject(&api);
    if (!objectMissing.count) {
        lease->_activation = api.duplicate(object);
        activated = lease->_activation && api.activate(lease->_activation, false);
    } else { [log appendFormat:@"MHA object activation missing symbols: %@.\n", FLCapability(objectMissing)]; }
    if (!activated) {
        NSArray *manualMissing = FLMissingManual(&api);
        if (!manualMissing.count) {
            char *token = api.token(object);
            if (token) { lease->_token = api.consume(token); free(token); }
        } else { [log appendFormat:@"MHA manual activation skipped; missing symbols: %@.\n", FLCapability(manualMissing)]; }
    }
    int ioError = 0;
    BOOL readable = (api.readableDirectory ?: FLReadDirectory)(root.fileSystemRepresentation, &ioError);
    [log appendFormat:@"MHA lsd class %llu: %@; activated %@; token %lld; container readable %@; errno %d.\n",
        (unsigned long long)kind, root, activated ? @"yes" : @"no", (long long)lease->_token, readable ? @"yes" : @"no", ioError];
    if (!readable) return nil;
    lease.cacheDirectory = cache;
    return lease;
}
- (void)dealloc {
    if (_token >= 0 && _api.release) _api.release(_token);
    if (_activation && _api.freeObject) _api.freeObject(_activation);
    if (_query && _api.dispose) _api.dispose(_query);
}
@end
#if defined(FL_CONTAINER_TESTING)
FLLSDContainerLease *FLTestOpenLSDLease(uint64_t kind, const FLContainerRuntime *runtime, NSMutableString *log) {
    return [FLLSDContainerLease openForClass:kind runtime:runtime log:log];
}
#endif
