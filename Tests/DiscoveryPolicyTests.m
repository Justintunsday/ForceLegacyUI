// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "FLStoreDiscovery.h"
#import "FLDeviceIdentity.h"
#import "FLContainerAccess.h"

@interface TestDiscoveryAccess : NSObject <FLStoreDiscoveryAccess>
@property (nonatomic, copy) NSArray<NSString *> *mapped;
@property (nonatomic, copy) NSDictionary<NSNumber *, NSString *> *metadata;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *stores;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *roots;
@property (nonatomic, copy) NSArray<NSString *> *inodes;
@property (nonatomic, strong) NSMutableArray<NSString *> *attempted;
@property (nonatomic) NSUInteger rootCalls;
@property (nonatomic) NSUInteger inodeCalls;
@end
@implementation TestDiscoveryAccess
- (instancetype)init {
    if ((self = [super init])) { _mapped = @[]; _metadata = @{}; _stores = @{}; _roots = @{}; _inodes = @[]; _attempted = [NSMutableArray array]; }
    return self;
}
- (NSArray<NSString *> *)mappedStorePathsWithLog:(NSMutableString *)log { (void)log; return self.mapped; }
- (NSString *)cacheDirectoryForContainerClass:(uint64_t)kind log:(NSMutableString *)log {
    [log appendFormat:@"Test metadata class %llu: %@.\n", (unsigned long long)kind, self.metadata[@(kind)] ?: @"denied/empty"];
    return self.metadata[@(kind)];
}
- (NSArray<NSString *> *)storePathsInDirectory:(NSString *)directory group:(NSString *)group log:(NSMutableString *)log {
    (void)group; [self.attempted addObject:directory]; [log appendFormat:@"Test cache probe: %@.\n", directory];
    return self.stores[directory] ?: @[];
}
- (NSArray<NSString *> *)cacheDirectoriesInRoot:(NSString *)root group:(NSString *)group deadline:(NSTimeInterval)deadline log:(NSMutableString *)log {
    (void)group; (void)deadline; (void)log; ++_rootCalls; return self.roots[root] ?: @[];
}
- (NSArray<NSString *> *)inodeCacheDirectoriesWithDeadline:(NSTimeInterval)deadline log:(NSMutableString *)log {
    (void)deadline; (void)log; ++_inodeCalls; return self.inodes;
}
@end

static void require(BOOL value, NSString *message) { if (!value) [NSException raise:@"DiscoveryRegression" format:@"%@", message]; }
static NSString *store(NSString *directory, NSString *suffix) {
    return [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"com.apple.LaunchServices-%@-v2.csstore", suffix]];
}
static NSString *find(TestDiscoveryAccess *access, NSString *cached, BOOL extended, NSMutableString *log, NSError **error) {
    return [FLStoreDiscovery findStoreUsing:access group:@"group.test.dedicated" cachedDirectory:cached extended:extended log:log error:error];
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray *passed = [NSMutableArray array];
        NSString *legacy = @"/private/var/db/lsd";
        NSString *fixed = @"/private/var/containers/Data/System/com.apple.lsd/Library/Caches";
        NSString *root = FLStoreContainerRoots().firstObject;
        NSString *uuid = @"04BA7A11-12F4-4567-89AB-0123456789AB";
        NSString *cache = [[root stringByAppendingPathComponent:uuid] stringByAppendingPathComponent:@"Library/Caches"];
        void (^test)(NSString *, void (^)(void)) = ^(NSString *name, void (^body)(void)) { body(); [passed addObject:name]; };
        @try {
            test(@"Path normalization stays lexical, stable and rejects traversal", ^{
                for (NSString *path in @[@"/var/db/lsd", @"/private/var/db/lsd", @"//var/./db/lsd/"]) {
                    NSString *normalized = FLNormalizeStorePath(path);
                    require([normalized isEqual:legacy] && [FLNormalizeStorePath(normalized) isEqual:legacy], @"Filesystem alias changed discovery identity");
                }
                require(!FLNormalizeStorePath(@"/var/db/../db/lsd").length && !FLNormalizeStorePath(@"var/db/lsd").length, @"Traversal or relative path accepted");
            });
            test(@"A container descendant yields a candidate without finding the store inode", ^{
                NSString *container = [root stringByAppendingPathComponent:uuid];
                require([FLCacheDirectoryForResolvedPath([container stringByAppendingPathComponent:@"Library/Preferences/service.plist"]) isEqual:cache], @"Container path was discarded without a store filename");
                require([FLCacheDirectoryForResolvedPath(container) isEqual:cache], @"Container directory itself was discarded");
                require(!FLCacheDirectoryForResolvedPath(@"/private/var/mobile/Containers/Data/Application/04BA7A11-12F4-4567-89AB-0123456789AB/Library/a"), @"Application data entered LS discovery");
            });
            test(@"Inode progress resumes only on the same volume and build", ^{
                NSDictionary *checkpoint = FLInodeCheckpoint(@"volume:build", 4319232);
                require(FLInodeStartForCheckpoint(checkpoint, @"volume:build") == 4319232, @"Search restarted instead of resuming");
                require(FLInodeStartForCheckpoint(checkpoint, @"other-volume:build") == 16, @"Stale volume checkpoint reused");
                require(FLInodeStartForCheckpoint(FLInodeCheckpoint(@"volume:build", 40000000), @"volume:build") == 16, @"Completed range did not restart");
                require(FLInodeStartForCheckpoint(@{@"context":@"volume:build", @"next":@4319232.5}, @"volume:build") == 16 &&
                    FLInodeStartForCheckpoint(@{@"context":@"volume:build", @"next":@(-1)}, @"volume:build") == 16, @"Malformed cursor accepted");
            });
            test(@"MHA identity requires explicit mode and unchanged bundle identifier", ^{
                require(FLHouseArrestIdentityAllowed(@"com.apple.mobile.MobileHouseArrest", @"house-arrest"), @"Dedicated identity refused");
                require(!FLHouseArrestIdentityAllowed(@"com.apple.mobile.MobileHouseArrest.TEAM", @"house-arrest") &&
                    !FLHouseArrestIdentityAllowed(@"org.forcelegacyui.app", @"house-arrest") &&
                    !FLHouseArrestIdentityAllowed(@"com.apple.mobile.MobileHouseArrest", @"app-group"), @"Rewritten or incidental identity enabled MHA");
                require(![FLLSDContainerLease openForClass:2 log:[NSMutableString string]], @"General application-data lease enabled");
            });
            test(@"Traversal backend cannot request unrelated file paths", ^{
                NSString *unrelated = @"/private/var/mobile/Containers/Data/Application/04BA7A11-12F4-4567-89AB-0123456789AB";
                require(!FLTraversalDomainForCacheDirectory(unrelated) &&
                    FLTraversalTokenForCacheDirectory(unrelated, [NSMutableString string]) == -100, @"Unrelated traversal reached private APIs");
                require([FLTraversalDomainForCacheDirectory(cache) hasSuffix:cache] &&
                    FLTraversalDomainForCacheDirectory(root) != nil, @"Allowed LS discovery target refused");
            });
            test(@"Architecture uses Mach-O CPU type and strips capability flags", ^{
                struct mach_header header = {0}; header.magic = MH_MAGIC_64; header.cputype = CPU_TYPE_ARM64;
                header.cpusubtype = CPU_SUBTYPE_ARM64_ALL;
                require([FLArchitectureForMachHeader(&header) isEqual:@"arm64"], @"arm64 executable misidentified");
                header.cpusubtype = CPU_SUBTYPE_ARM64E | CPU_SUBTYPE_LIB64;
                require([FLArchitectureForMachHeader(&header) isEqual:@"arm64e"], @"arm64e capability flags misidentified");
                header.cputype = CPU_TYPE_X86_64;
                require([FLArchitectureForMachHeader(&header) isEqual:@"x86_64"], @"Simulator architecture misidentified");
                header.magic = 0;
                require([FLArchitectureForMachHeader(&header) isEqual:@"unknown"] &&
                    [FLArchitectureForMachHeader(NULL) isEqual:@"unknown"], @"Unknown architecture guessed");
            });
            test(@"Denied metadata still probes fixed lsd locations", ^{
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; a.stores = @{legacy:@[store(legacy, @"1")]};
                require([find(a, nil, NO, [NSMutableString string], NULL) isEqual:store(legacy, @"1")], @"No fallback after empty metadata");
                require([a.attempted containsObject:fixed] && [a.attempted containsObject:legacy], @"Known paths skipped");
                require(!a.rootCalls && !a.inodeCalls, @"Standard scan unexpectedly ran extended search");
            });
            test(@"Empty discovery preserves actionable diagnostic log", ^{
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; NSError *error = nil;
                require(!find(a, nil, NO, [NSMutableString string], &error), @"Empty discovery selected a store");
                require([error.localizedDescription containsString:@"denied/empty"] &&
                    [error.localizedDescription containsString:@"Extended discovery not run"], @"Failure lost source diagnostics");
            });
            test(@"Mapped active file excludes unrelated cache files", ^{
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; a.mapped = @[store(cache, @"active")];
                a.stores = @{cache:@[store(cache, @"old"), store(cache, @"active")], legacy:@[store(legacy, @"other")]};
                require([find(a, nil, YES, [NSMutableString string], NULL) isEqual:store(cache, @"active")], @"Mapped identity ignored");
                require(a.attempted.count == 1 && !a.rootCalls && !a.inodeCalls, @"Mapped scan broadened unnecessarily");
            });
            test(@"Multiple mapped stores refuse before granting directories", ^{
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; a.mapped = @[store(cache, @"1"), store(cache, @"2")];
                require(!find(a, nil, YES, [NSMutableString string], NULL) && !a.attempted.count, @"Ambiguous mapped store was opened");
            });
            test(@"Multiple readable stores do not select an arbitrary file", ^{
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; a.stores = @{legacy:@[store(legacy, @"1"), store(legacy, @"2")]};
                require(!find(a, nil, YES, [NSMutableString string], NULL), @"Ambiguous fallback accepted");
            });
            test(@"Extended search finds UUID cache after all initial queries fail", ^{
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; a.roots = @{root:@[cache]}; a.stores = @{cache:@[store(cache, @"1")]};
                require([find(a, nil, YES, [NSMutableString string], NULL) isEqual:store(cache, @"1")], @"Root fallback skipped");
                require(a.rootCalls && !a.inodeCalls, @"Successful root fallback unnecessarily scanned inodes");
            });
            test(@"Root fallback rejects other application data and nested paths", ^{
                NSString *unrelated = @"/private/var/mobile/Containers/Data/Application/04BA7A11-12F4-4567-89AB-0123456789AB/Library/Caches";
                NSString *nested = [cache stringByAppendingPathComponent:@"Library/Caches"];
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; a.roots = @{root:@[unrelated, nested, legacy]};
                a.stores = @{unrelated:@[store(unrelated, @"1")], nested:@[store(nested, @"2")]};
                require(!find(a, unrelated, YES, [NSMutableString string], NULL), @"Unrelated directory selected");
                require(![a.attempted containsObject:unrelated] && ![a.attempted containsObject:nested], @"Probed unrelated application data");
            });
            test(@"Bounded inode fallback is attempted after empty roots", ^{
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; a.inodes = @[cache]; a.stores = @{cache:@[store(cache, @"1")]};
                require([find(a, nil, YES, [NSMutableString string], NULL) isEqual:store(cache, @"1")] && a.inodeCalls == 1, @"Inode fallback skipped");
            });
            test(@"Cached aliases and duplicate file results collapse safely", ^{
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; NSString *alias = [cache substringFromIndex:8];
                a.metadata = @{@10:cache, @12:alias}; a.stores = @{cache:@[store(cache, @"1"), store(cache, @"1")]};
                require([find(a, alias, NO, [NSMutableString string], NULL) isEqual:store(cache, @"1")], @"Alias changed identity");
                require([[a.attempted filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == %@", cache]] count] == 1, @"Duplicate directory grants");
            });
            test(@"Directory listing cannot return a file from another directory", ^{
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; a.stores = @{fixed:@[store(cache, @"1")]};
                require(!find(a, nil, NO, [NSMutableString string], NULL), @"Escaping file result accepted");
            });
            test(@"Extended root candidate count is bounded", ^{
                TestDiscoveryAccess *a = [TestDiscoveryAccess new]; NSMutableArray *directories = [NSMutableArray array];
                for (NSUInteger i = 0; i < 300; ++i) {
                    NSString *identifier = [NSString stringWithFormat:@"00000000-0000-0000-0000-%012lu", (unsigned long)i];
                    [directories addObject:[[root stringByAppendingPathComponent:identifier] stringByAppendingPathComponent:@"Library/Caches"]];
                }
                a.roots = @{root:directories}; require(!find(a, nil, YES, [NSMutableString string], NULL), @"Empty bounded search selected a store");
                require(a.attempted.count == 259, @"Container search exceeded its directory bound");
            });
        } @catch (NSException *exception) { fprintf(stderr, "%s\n", exception.reason.UTF8String); return 1; }
        NSDictionary *result = @{@"passed":@YES, @"cases":passed, @"physicalDeviceAccessTested":@NO,
            @"scope":@"Production discovery coordinator with injected denied/empty/path/ambiguity responses; no sandbox grants"};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        if (argc > 1 && ![json writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES]) return 2;
        printf("%lu discovery policy regression cases passed.\n", (unsigned long)passed.count);
    }
    return 0;
}
