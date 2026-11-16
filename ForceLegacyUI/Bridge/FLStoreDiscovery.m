// SPDX-License-Identifier: GPL-3.0-or-later
#import "FLStoreDiscovery.h"

NSString *FLNormalizeStorePath(NSString *path) {
    if (![path isKindOfClass:NSString.class]) return @"";
    if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
    return path.stringByStandardizingPath;
}
NSArray<NSString *> *FLStoreContainerRoots(void) {
    return @[@"/private/var/mobile/Containers/Data/InternalDaemon", @"/private/var/containers/Data/System"];
}
BOOL FLIsLaunchServicesStoreName(NSString *name) {
    return [name hasPrefix:@"com.apple.LaunchServices-"] && [name hasSuffix:@"-v2.csstore"] &&
        [name.lastPathComponent isEqualToString:name];
}
BOOL FLIsAllowedStoreDirectory(NSString *path) {
    path = FLNormalizeStorePath(path);
    if ([path isEqualToString:@"/private/var/db/lsd"]) return YES;
    if (![path hasSuffix:@"/Library/Caches"]) return NO;
    NSString *container = [[path stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    if (![FLStoreContainerRoots() containsObject:container.stringByDeletingLastPathComponent]) return NO;
    return [[NSUUID alloc] initWithUUIDString:container.lastPathComponent] != nil ||
        [container.lastPathComponent isEqualToString:@"com.apple.lsd"];
}
static NSString *FLAllowedStore(NSString *path) {
    path = FLNormalizeStorePath(path);
    return FLIsLaunchServicesStoreName(path.lastPathComponent) &&
        FLIsAllowedStoreDirectory(path.stringByDeletingLastPathComponent) ? path : nil;
}

@implementation FLStoreDiscovery
+ (NSString *)findStoreUsing:(id<FLStoreDiscoveryAccess>)access group:(NSString *)group
             cachedDirectory:(NSString *)cached extended:(BOOL)extended
                         log:(NSMutableString *)log error:(NSError **)error {
    [log appendFormat:@"Store discovery mode: %@.\n", extended ? @"extended" : @"standard"];
    NSMutableOrderedSet<NSString *> *mapped = [NSMutableOrderedSet orderedSet];
    for (NSString *path in [access mappedStorePathsWithLog:log]) {
        NSString *allowed = FLAllowedStore(path);
        if (allowed) [mapped addObject:allowed];
    }
    [log appendFormat:@"Mapped store candidates: %lu.\n", (unsigned long)mapped.count];
    NSMutableOrderedSet<NSString *> *directories = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    void (^probe)(NSString *) = ^(NSString *directory) {
        directory = FLNormalizeStorePath(directory);
        if (!FLIsAllowedStoreDirectory(directory) || [visited containsObject:directory]) return;
        [visited addObject:directory];
        for (NSString *path in [access storePathsInDirectory:directory group:group log:log]) {
            NSString *allowed = FLAllowedStore(path);
            if (allowed && [allowed.stringByDeletingLastPathComponent isEqualToString:directory] &&
                (!mapped.count || [mapped containsObject:allowed])) [candidates addObject:allowed];
        }
    };
    if (mapped.count <= 1) {
        if (mapped.count) {
            [directories addObject:[mapped.firstObject stringByDeletingLastPathComponent]];
        } else {
            for (NSNumber *kind in @[@10, @12]) {
                NSString *directory = [access cacheDirectoryForContainerClass:kind.unsignedLongLongValue log:log];
                if (FLIsAllowedStoreDirectory(directory)) [directories addObject:FLNormalizeStorePath(directory)];
            }
            if (FLIsAllowedStoreDirectory(cached)) [directories addObject:FLNormalizeStorePath(cached)];
            // Metadata queries can return nothing in a sandbox. Still try the documented upstream locations.
            [directories addObjectsFromArray:@[@"/private/var/containers/Data/System/com.apple.lsd/Library/Caches",
                                               @"/private/var/db/lsd"]];
        }
        [log appendFormat:@"Initial cache directories: %lu.\n", (unsigned long)directories.count];
        for (NSString *directory in directories) probe(directory);
        if (!candidates.count && !mapped.count && extended) {
            NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 10;
            NSUInteger count = 0;
            for (NSString *root in FLStoreContainerRoots()) {
                if (NSProcessInfo.processInfo.systemUptime >= deadline || count >= 256) break;
                for (NSString *directory in [access cacheDirectoriesInRoot:root group:group deadline:deadline log:log]) {
                    NSString *normalized = FLNormalizeStorePath(directory);
                    NSString *container = [[normalized stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
                    if (!FLIsAllowedStoreDirectory(normalized) || ![container.stringByDeletingLastPathComponent isEqualToString:root]) continue;
                    if (NSProcessInfo.processInfo.systemUptime >= deadline || count >= 256) break;
                    if (![visited containsObject:normalized]) { ++count; probe(normalized); }
                }
            }
            [log appendFormat:@"Extended container search: %lu cache directories attempted (limit 256; time budget 10 seconds).\n", (unsigned long)count];
            if (!candidates.count) {
                for (NSString *path in [access inodeStorePathsWithDeadline:NSProcessInfo.processInfo.systemUptime + 8 log:log]) {
                    NSString *allowed = FLAllowedStore(path);
                    if (allowed) probe(allowed.stringByDeletingLastPathComponent);
                }
            }
        } else if (!extended && !candidates.count) {
            [log appendString:@"Extended discovery not run. Use Diagnostics > Extended Store Discovery for bounded container/inode search.\n"];
        }
    }
    if (mapped.count > 1 || candidates.count != 1) {
        NSString *reason = mapped.count > 1 ? @"Multiple mapped stores; the active store is ambiguous."
            : [NSString stringWithFormat:@"Read-only store discovery found %lu distinct candidates; exactly one is required.", (unsigned long)candidates.count];
        if (error) *error = [NSError errorWithDomain:@"ForceLegacyUI" code:1
            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@\n%@", reason, log]}];
        return nil;
    }
    [log appendFormat:@"Selected read-only store: %@.\n", candidates.firstObject];
    return candidates.firstObject;
}
@end
