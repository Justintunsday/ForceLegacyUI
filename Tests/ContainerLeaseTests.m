// SPDX-License-Identifier: GPL-3.0-or-later
#import "FLContainerAccess.h"
#import "FLContainerRuntime.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>

static struct {
    unsigned queries, disposed, copies, freedObjects, activations, tokens, consumes, releases, probes, metadataCallbacks, existenceChecks;
    uint64_t kind, flags, part;
    BOOL readable, activation, result, exists;
    const char *root;
    char identifier[128];
    char domain[1024];
} state;
static void check(BOOL value, NSString *message) { if (!value) [NSException raise:@"ContainerLeaseRegression" format:@"%@", message]; }
static void *queryCreate(void) { ++state.queries; return malloc(1); }
static void setKind(void *query, uint64_t value) { (void)query; state.kind = value; }
static void setIdentifiers(void *query, xpc_object_t value) {
    (void)query; const char *text = xpc_string_get_string_ptr(value);
    snprintf(state.identifier, sizeof(state.identifier), "%s", text ?: "");
}
static void setFlags(void *query, uint64_t value) { (void)query; state.flags = value; }
static void setPart(void *query, uint64_t value) { (void)query; state.part = value; }
static void setDomain(void *query, const char *value) { (void)query; snprintf(state.domain, sizeof(state.domain), "%s", value); }
static void *getResult(void *query) { return state.result ? query : NULL; }
static const char *getPath(void *object) { (void)object; return state.root; }
static void dispose(void *query) { ++state.disposed; free(query); }
static void *copyObject(void *object) { (void)object; ++state.copies; return malloc(1); }
static bool activate(void *object, bool ignored) { (void)object; (void)ignored; ++state.activations; return state.activation; }
static void freeObject(void *object) { ++state.freedObjects; free(object); }
static char *copyToken(void *object) { (void)object; ++state.tokens; return strdup("injected-test-token"); }
static char *copyNoToken(void *object) { (void)object; ++state.tokens; return NULL; }
static int64_t consume(const char *token) { (void)token; ++state.consumes; return 73; }
static int releaseToken(int64_t token) { check(token == 73, @"Wrong manual token released"); ++state.releases; return 0; }
static BOOL readable(const char *path, int *error) {
    check(strcmp(path, state.root) == 0, @"Unexpected directory probe"); ++state.probes;
    if (error) *error = state.readable ? 0 : EACCES; return state.readable;
}
static BOOL existing(const char *path, int *error) {
    check(strcmp(path, state.root) == 0, @"Existence probe escaped requested UUID"); ++state.existenceChecks;
    if (error) *error = state.exists ? 0 : EPERM;
    return state.exists;
}
static const char *getIdentifier(void *object) { return (const char *)object; }
static bool iterateMetadata(void *query, bool (^callback)(void *)) {
    (void)query;
    const char *identifiers[] = {"org.example.one", "org.example.one", "../bad", "org.example.two", "org.example.three"};
    for (unsigned index = 0; index < 5; ++index) {
        ++state.metadataCallbacks;
        if (!callback((void *)identifiers[index])) return false;
    }
    return true;
}
static FLContainerRuntime runtime(void) {
    memset(&state, 0, sizeof(state)); state.readable = YES; state.activation = YES; state.result = YES;
    state.root = "/private/var/mobile/Containers/Data/InternalDaemon/04BA7A11-12F4-4567-89AB-0123456789AB";
    FLContainerRuntime api = {0};
    api.create = queryCreate; api.kind = setKind; api.identifiers = setIdentifiers;
    api.flags = setFlags; api.result = getResult; api.path = getPath; api.dispose = dispose;
    api.duplicate = copyObject; api.activate = activate; api.freeObject = freeObject;
    api.readableDirectory = readable;
    return api;
}
static FLContainerRuntime bundleTraversalRuntime(void) {
    FLContainerRuntime api = runtime();
    state.root = "/private/var/containers/Bundle/Application/04BA7A11-12F4-4567-89AB-0123456789AB";
    state.exists = YES; api.existingDirectory = existing;
    api.groups = setIdentifiers; api.part = setPart; api.domain = setDomain;
    api.token = copyToken; api.consume = consume; api.release = releaseToken;
    return api;
}
NSArray<NSString *> *FLRunContainerLeaseTests(void) {
    NSMutableArray *passed = [NSMutableArray array];
    void (^test)(NSString *, void (^)(void)) = ^(NSString *name, void (^body)(void)) { body(); [passed addObject:name]; };
    test(@"Production symbol resolution uses the operation part and part-domain APIs", ^{
        NSMutableArray *lookedUp = [NSMutableArray array];
        FLContainerRuntime api = FLTestResolveContainerRuntime(^void *(const char *name) {
            [lookedUp addObject:[NSString stringWithUTF8String:name]];
            if (strcmp(name, "container_query_operation_set_part") == 0) return (void *)setPart;
            if (strcmp(name, "container_query_operation_set_part_domain") == 0) return (void *)setDomain;
            return NULL;
        });
        check(api.part == setPart && api.domain == setDomain, @"Correct exported part APIs were not resolved");
        check(![lookedUp containsObject:@"container_query_set_part"] && ![lookedUp containsObject:@"container_query_set_part_domain"], @"Nonexistent API names returned to the production loader");
    });
    test(@"Bundle traversal accepts one UUID parent and rejects roots, data and nested paths before queries", ^{
        FLContainerRuntime api = bundleTraversalRuntime(); NSString *root = [NSString stringWithUTF8String:state.root];
        check([FLTraversalDomainForBundleContainer(root) hasSuffix:root], @"Valid UUID parent refused");
        check([FLTraversalDomainForBundleContainer([root substringFromIndex:8]) hasSuffix:root], @"Lexical /var alias was not canonicalized");
        check(!FLTraversalDomainForCacheDirectory(root), @"Bundle scope leaked into LS-only cache policy");
        for (NSString *path in @[@"/private/var/containers/Bundle/Application", [root stringByAppendingPathComponent:@"Example.app"],
            [root stringByAppendingPathComponent:@"../Other"], @"/private/var/mobile/Containers/Data/Application/04BA7A11-12F4-4567-89AB-0123456789AB"]) {
            check(FLTestBundleTraversalToken(path, &api, [NSMutableString string]) == -100, @"Unrelated traversal target accepted");
        }
        check(!state.queries && !state.existenceChecks && !state.tokens, @"Rejected path reached filesystem or token APIs");
    });
    test(@"Bundle traversal binds query context and leaves a paired token for the metadata reader", ^{
        FLContainerRuntime api = bundleTraversalRuntime(); NSString *root = [NSString stringWithUTF8String:state.root];
        check(FLTestBundleTraversalToken(root, &api, [NSMutableString string]) == 73, @"Traversal token unavailable");
        check(state.kind == 13 && state.flags == 0x8000000000ULL && state.part == 3 &&
            strcmp(state.identifier, "systemgroup.com.apple.mobilegestaltcache") == 0 && strstr(state.domain, state.root), @"Traversal query escaped fixed context");
        check(state.existenceChecks == 1 && state.disposed == 1 && state.consumes == 1 && !state.releases, @"Query cleanup or token ownership failed");
        api.release(73); check(state.releases == 1, @"Metadata reader could not release traversal token");
    });
    test(@"Bundle traversal refuses unverifiable directories, missing release APIs and denied tokens", ^{
        FLContainerRuntime api = bundleTraversalRuntime(); NSString *root = [NSString stringWithUTF8String:state.root];
        state.exists = NO;
        check(FLTestBundleTraversalToken(root, &api, [NSMutableString string]) == -105 && !state.queries, @"Unverified directory reached a sandbox query");
        api = bundleTraversalRuntime(); api.release = NULL;
        check(FLTestBundleTraversalToken(root, &api, [NSMutableString string]) == -101 && !state.queries && !state.consumes, @"Unpaired traversal token was consumed");
        api = bundleTraversalRuntime(); state.result = NO;
        check(FLTestBundleTraversalToken(root, &api, [NSMutableString string]) == -103 && state.disposed == 1 && !state.tokens, @"Denied query leaked or copied a token");
        api = bundleTraversalRuntime(); api.token = copyNoToken;
        check(FLTestBundleTraversalToken(root, &api, [NSMutableString string]) == -104 && state.disposed == 1 && !state.consumes, @"Absent token was consumed or query leaked");
    });
    test(@"Bundle-root traversal has one fixed scope and still requires existence and paired release", ^{
        FLContainerRuntime api = bundleTraversalRuntime(); state.root = "/private/var/containers/Bundle/Application";
        check(FLTestBundleRootTraversalToken(&api, [NSMutableString string]) == 73, @"Fixed-root traversal token unavailable");
        check(state.kind == 13 && strcmp(state.identifier, "systemgroup.com.apple.mobilegestaltcache") == 0 &&
            strcmp(state.domain, "../../../../../../../../private/var/containers/Bundle/Application") == 0 &&
            state.disposed == 1 && !state.releases, @"Root query escaped fixed scope or lost token ownership");
        api.release(73);
        api = bundleTraversalRuntime(); state.root = "/private/var/containers/Bundle/Application"; state.exists = NO;
        check(FLTestBundleRootTraversalToken(&api, [NSMutableString string]) == -105 && !state.queries, @"Unverifiable root reached query");
        api = bundleTraversalRuntime(); state.root = "/private/var/containers/Bundle/Application"; api.release = NULL;
        check(FLTestBundleRootTraversalToken(&api, [NSMutableString string]) == -101 && !state.queries && !state.consumes, @"Root token consumed without release API");
    });
    test(@"MCM catalog reads metadata without token or object activation APIs", ^{
        FLContainerRuntime api = runtime(); api.iterate = iterateMetadata; api.identifier = getIdentifier;
        NSArray<NSDictionary<NSString *, id> *> *records = FLTestMHAAppDataCatalog(&api, 4096, [NSMutableString string]);
        check(records.count == 3 && state.kind == 2 && state.flags == 0x100000000ULL, @"App-data metadata query was not bounded/deduplicated");
        check([records.firstObject[@"bundlePath"] isEqual:@""] && [records.firstObject[@"sdk"] isEqual:@""], @"Data metadata fabricated bundle/SDK fields");
        check(!state.activations && !state.tokens && !state.probes && state.disposed == 1, @"Metadata enumeration acquired data access or leaked query ownership");
    });
    test(@"MCM catalog stops at the requested record limit", ^{
        FLContainerRuntime api = runtime(); api.iterate = iterateMetadata; api.identifier = getIdentifier;
        NSArray *records = FLTestMHAAppDataCatalog(&api, 1, [NSMutableString string]);
        check(records.count == 1 && state.metadataCallbacks == 1 && state.disposed == 1, @"Metadata limit was not enforced");
    });
    test(@"Missing metadata iterator is independent of MHA lease capabilities", ^{
        FLContainerRuntime api = runtime(); NSMutableString *log = [NSMutableString string];
        check(!FLTestMHAAppDataCatalog(&api, 4096, log).count && !state.queries, @"Incomplete metadata API issued a query");
        check([log containsString:@"container_query_iterate_results_sync"], @"Missing metadata symbol was hidden");
    });
    test(@"MHA object activation works without manual-token or optional part symbols", ^{
        FLContainerRuntime api = runtime();
        @autoreleasepool {
            __attribute__((objc_precise_lifetime)) FLLSDContainerLease *lease = FLTestOpenLSDLease(10, &api, [NSMutableString string]);
            check(lease != nil && state.activations == 1, @"Optional manual APIs blocked object activation");
            check(state.kind == 10 && state.flags == 0x900000000ULL && strcmp(state.identifier, "com.apple.lsd") == 0, @"Query escaped the fixed lsd contract");
            check(!state.disposed && !state.freedObjects, @"Lease released before the read-only session ended");
        }
        check(state.disposed == 1 && state.freedObjects == 1 && !state.consumes, @"Object/query ownership cleanup failed");
    });
    test(@"Failed object activation can use a paired manual token route", ^{
        FLContainerRuntime api = runtime(); state.activation = NO;
        api.token = copyToken; api.consume = consume; api.release = releaseToken;
        @autoreleasepool {
            __attribute__((objc_precise_lifetime)) FLLSDContainerLease *lease = FLTestOpenLSDLease(12, &api, [NSMutableString string]);
            check(lease != nil && state.tokens == 1 && state.consumes == 1 && !state.releases, @"Manual fallback not retained");
        }
        check(state.releases == 1 && state.freedObjects == 1 && state.disposed == 1, @"Fallback resources leaked");
    });
    test(@"Missing release API never consumes an unreleasable token", ^{
        FLContainerRuntime api = runtime(); state.readable = NO;
        api.duplicate = NULL; api.activate = NULL; api.freeObject = NULL;
        api.token = copyToken; api.consume = consume;
        NSMutableString *log = [NSMutableString string];
        @autoreleasepool { check(!FLTestOpenLSDLease(10, &api, log), @"Unreadable directory accepted"); }
        check(!state.tokens && !state.consumes && state.disposed == 1, @"Unreleasable token was used");
        check([log containsString:@"sandbox_extension_release"], @"Missing symbol was hidden by a generic API error");
    });
    test(@"Activation success still requires actual directory readability", ^{
        FLContainerRuntime api = runtime(); state.readable = NO;
        @autoreleasepool { check(!FLTestOpenLSDLease(10, &api, [NSMutableString string]), @"Activation was mistaken for readable access"); }
        check(state.probes == 1 && state.disposed == 1 && state.freedObjects == 1, @"Failed-read lease cleanup failed");
    });
    test(@"Existing readable access does not require optional activation helpers", ^{
        FLContainerRuntime api = runtime(); api.duplicate = NULL; api.activate = NULL; api.freeObject = NULL;
        @autoreleasepool {
            __attribute__((objc_precise_lifetime)) FLLSDContainerLease *lease = FLTestOpenLSDLease(10, &api, [NSMutableString string]);
            check(lease != nil && state.probes == 1, @"Readable root was rejected because optional APIs were absent");
        }
        check(state.disposed == 1 && !state.activations && !state.consumes, @"Existing-access lifetime failed");
    });
    test(@"An unrelated returned container is rejected before activation", ^{
        FLContainerRuntime api = runtime(); state.root = "/private/var/mobile/Containers/Data/Application/04BA7A11-12F4-4567-89AB-0123456789AB";
        @autoreleasepool { check(!FLTestOpenLSDLease(10, &api, [NSMutableString string]), @"Unrelated container accepted"); }
        check(!state.activations && !state.probes && state.disposed == 1, @"Unrelated container was accessed");
    });
    test(@"Missing query symbols are identified before creating a query", ^{
        FLContainerRuntime api = runtime(); api.flags = NULL; NSMutableString *log = [NSMutableString string];
        check(!FLTestOpenLSDLease(10, &api, log) && !state.queries, @"Incomplete transport issued a query");
        check([log containsString:@"container_query_operation_set_flags"], @"Missing query symbol was not identified");
    });
    test(@"A denied MHA query releases ownership without activation", ^{
        FLContainerRuntime api = runtime(); state.result = NO;
        @autoreleasepool { check(!FLTestOpenLSDLease(10, &api, [NSMutableString string]), @"Denied query accepted"); }
        check(state.disposed == 1 && !state.activations && !state.probes, @"Denied query leaked or proceeded");
    });
    return passed;
}
