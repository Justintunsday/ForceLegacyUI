// SPDX-License-Identifier: GPL-3.0-or-later
// Independent, LS-only implementation informed by 3105 / MHA-C2 and bad_query research.
#import "FLContainerAccess.h"
#import "FLStoreDiscovery.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <xpc/xpc.h>

BOOL FLHouseArrestIdentityAllowed(NSString *bundleID, NSString *mode) {
    if (![bundleID isKindOfClass:NSString.class] || ![mode isKindOfClass:NSString.class]) return NO;
    return [mode isEqualToString:@"house-arrest"] && [bundleID isEqualToString:@"com.apple.mobile.MobileHouseArrest"];
}
NSString *FLTraversalDomainForCacheDirectory(NSString *directory) {
    directory = FLNormalizeStorePath(directory);
    if (!FLIsAllowedStoreDirectory(directory) && ![FLStoreContainerRoots() containsObject:directory]) return nil;
    NSMutableArray *parents = [NSMutableArray array];
    for (unsigned depth = 0; depth < 8; ++depth) [parents addObject:@".."];
    return [[parents componentsJoinedByString:@"/"] stringByAppendingString:directory];
}
typedef struct {
    void *(*create)(void);
    void (*kind)(void *, uint64_t);
    void (*identifiers)(void *, xpc_object_t);
    void (*groups)(void *, xpc_object_t);
    void (*flags)(void *, uint64_t);
    void (*part)(void *, uint64_t);
    void (*domain)(void *, const char *);
    void *(*result)(void *);
    const char *(*path)(void *);
    char *(*token)(void *);
    void *(*duplicate)(void *);
    bool (*activate)(void *, bool);
    void (*freeObject)(void *);
    void (*dispose)(void *);
    int64_t (*consume)(const char *);
    int (*release)(int64_t);
    void *(*failure)(void *);
    const char *(*message)(void *);
    int (*posix)(void *);
} FLContainerAPI;
static FLContainerAPI *FLContainerFunctions(void) {
    static FLContainerAPI api; static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *library = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
        if (!library) return;
#define FL_SYMBOL(field, name) api.field = (__typeof(api.field))dlsym(library, name)
        FL_SYMBOL(create, "container_query_create");
        FL_SYMBOL(kind, "container_query_set_class");
        FL_SYMBOL(identifiers, "container_query_set_identifiers");
        FL_SYMBOL(groups, "container_query_set_group_identifiers");
        FL_SYMBOL(flags, "container_query_operation_set_flags");
        FL_SYMBOL(part, "container_query_set_part");
        FL_SYMBOL(domain, "container_query_set_part_domain");
        FL_SYMBOL(result, "container_query_get_single_result");
        FL_SYMBOL(path, "container_object_get_path");
        FL_SYMBOL(token, "container_copy_sandbox_token");
        FL_SYMBOL(duplicate, "container_object_copy");
        FL_SYMBOL(activate, "container_object_sandbox_extension_activate");
        FL_SYMBOL(freeObject, "container_object_free");
        FL_SYMBOL(dispose, "container_query_free");
        FL_SYMBOL(failure, "container_query_get_last_error");
        FL_SYMBOL(message, "container_error_get_message");
        FL_SYMBOL(posix, "container_error_get_posix_errno");
#undef FL_SYMBOL
        api.consume = dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
        api.release = dlsym(RTLD_DEFAULT, "sandbox_extension_release");
        // The resolver intentionally keeps the dylib loaded while leases hold function pointers.
    });
    return &api;
}
static BOOL FLTokenAPIAvailable(FLContainerAPI *api) {
    return api->create && api->kind && api->flags && api->part && api->result &&
        api->token && api->dispose && api->consume && api->release;
}
static void FLLogQueryFailure(FLContainerAPI *api, void *query, NSMutableString *log) {
    void *failure = api->failure ? api->failure(query) : NULL;
    int code = failure && api->posix ? api->posix(failure) : 0;
    const char *message = failure && api->message ? api->message(failure) : NULL;
    [log appendFormat:@"Container query detail: posix %d; %s.\n", code, message ?: "no detail returned"];
}
int64_t FLTraversalTokenForCacheDirectory(NSString *directory, NSMutableString *log) {
    NSString *domain = FLTraversalDomainForCacheDirectory(directory);
    if (!domain) { [log appendString:@"Traversal fallback refused a path outside LS discovery policy.\n"]; return -100; }
    FLContainerAPI *api = FLContainerFunctions();
    if (!FLTokenAPIAvailable(api) || !api->groups || !api->domain) {
        [log appendString:@"Traversal fallback API unavailable.\n"]; return -101;
    }
    void *query = api->create();
    if (!query) return -102;
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
}
@property (nonatomic, readwrite, copy) NSString *cacheDirectory;
@end
@implementation FLLSDContainerLease
- (instancetype)init { if ((self = [super init])) _token = -1; return self; }
+ (instancetype)openForClass:(uint64_t)kind log:(NSMutableString *)log {
    if (!FLHouseArrestIdentityAllowed(NSBundle.mainBundle.bundleIdentifier ?: @"",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"FLAccessMode"] ?: @"") || (kind != 10 && kind != 12)) return nil;
    FLContainerAPI *api = FLContainerFunctions();
    if (!FLTokenAPIAvailable(api) || !api->identifiers || !api->path) {
        [log appendString:@"MHA lsd lease API unavailable.\n"]; return nil;
    }
    FLLSDContainerLease *lease = [FLLSDContainerLease new];
    lease->_query = api->create(); if (!lease->_query) return nil;
    api->kind(lease->_query, kind);
    xpc_object_t identifier = xpc_string_create("com.apple.lsd");
    api->identifiers(lease->_query, identifier); api->part(lease->_query, 0);
    api->flags(lease->_query, 0x900000000ULL);
    void *object = api->result(lease->_query);
    if (!object) {
        [log appendFormat:@"MHA lsd class %llu: no result.\n", (unsigned long long)kind]; FLLogQueryFailure(api, lease->_query, log); return nil;
    }
    const char *raw = api->path(object);
    NSString *root = raw ? FLNormalizeStorePath([NSString stringWithUTF8String:raw]) : @"";
    NSString *cache = [root stringByAppendingPathComponent:@"Library/Caches"];
    if (!root.length || !FLIsAllowedStoreDirectory(cache)) { [log appendString:@"MHA lsd path outside cache policy.\n"]; return nil; }
    BOOL activated = NO;
    if (api->duplicate && api->activate && api->freeObject) {
        lease->_activation = api->duplicate(object);
        activated = lease->_activation && api->activate(lease->_activation, false);
    }
    if (!activated) {
        char *token = api->token(object);
        if (token) { lease->_token = api->consume(token); free(token); }
    }
    int descriptor = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    BOOL readable = descriptor >= 0; if (descriptor >= 0) close(descriptor);
    [log appendFormat:@"MHA lsd class %llu: %@; activated %@; token %lld; container readable %@.\n", (unsigned long long)kind, root,
        activated ? @"yes" : @"no", (long long)lease->_token, readable ? @"yes" : @"no"];
    if (!readable) return nil;
    lease.cacheDirectory = cache;
    return lease;
}
- (void)dealloc {
    FLContainerAPI *api = FLContainerFunctions();
    if (_token >= 0 && api->release) api->release(_token);
    if (_activation && api->freeObject) api->freeObject(_activation);
    if (_query && api->dispose) api->dispose(_query);
}
@end
