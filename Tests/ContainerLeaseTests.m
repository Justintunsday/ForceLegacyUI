// SPDX-License-Identifier: GPL-3.0-or-later
#import "FLContainerAccess.h"
#import "FLContainerRuntime.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>

static struct {
    unsigned queries, disposed, copies, freedObjects, activations, tokens, consumes, releases, probes, metadataCallbacks;
    uint64_t kind, flags;
    BOOL readable, activation, result;
    const char *root;
    char identifier[128];
} state;
static void check(BOOL value, NSString *message) { if (!value) [NSException raise:@"ContainerLeaseRegression" format:@"%@", message]; }
static void *queryCreate(void) { ++state.queries; return malloc(1); }
static void setKind(void *query, uint64_t value) { (void)query; state.kind = value; }
static void setIdentifiers(void *query, xpc_object_t value) {
    (void)query; const char *text = xpc_string_get_string_ptr(value);
    snprintf(state.identifier, sizeof(state.identifier), "%s", text ?: "");
}
static void setFlags(void *query, uint64_t value) { (void)query; state.flags = value; }
static void setPart(void *query, uint64_t value) { (void)query; (void)value; }
static void setDomain(void *query, const char *value) { (void)query; (void)value; }
static void *getResult(void *query) { return state.result ? query : NULL; }
static const char *getPath(void *object) { (void)object; return state.root; }
static void dispose(void *query) { ++state.disposed; free(query); }
static void *copyObject(void *object) { (void)object; ++state.copies; return malloc(1); }
static bool activate(void *object, bool ignored) { (void)object; (void)ignored; ++state.activations; return state.activation; }
static void freeObject(void *object) { ++state.freedObjects; free(object); }
static char *copyToken(void *object) { (void)object; ++state.tokens; return strdup("injected-test-token"); }
static int64_t consume(const char *token) { (void)token; ++state.consumes; return 73; }
static int releaseToken(int64_t token) { check(token == 73, @"Wrong manual token released"); ++state.releases; return 0; }
static BOOL readable(const char *path, int *error) {
    check(strcmp(path, state.root) == 0, @"Unexpected directory probe"); ++state.probes;
    if (error) *error = state.readable ? 0 : EACCES; return state.readable;
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
