// SPDX-License-Identifier: GPL-3.0-or-later
#import "FLStoreDiscovery.h"

NSString *FLNormalizeStorePath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"]) return @"";
    // NSString standardizingPath can remove /private based on the live filesystem.
    // Keep allowlist comparison lexical and idempotent even for inaccessible paths.
    NSMutableArray *components = [NSMutableArray array];
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if ([component isEqualToString:@".."]) return @"";
        if (component.length && ![component isEqualToString:@"."]) [components addObject:component];
    }
    path = [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];
    if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
    return path;
}
NSArray<NSString *> *FLStoreContainerRoots(void) {
    return @[@"/private/var/mobile/Containers/Data/InternalDaemon", @"/private/var/mobile/Containers/Data/System",
             @"/private/var/containers/Data/System"];
}
BOOL FLIsLaunchServicesStoreName(NSString *name) {
    return [name hasPrefix:@"com.apple.LaunchServices-"] && [name hasSuffix:@"-v2.csstore"] &&
        [name.lastPathComponent isEqualToString:name];
}
BOOL FLIsDiagnosticLSStoreName(NSString *name) {
    NSString *prefix = @"SystemDataOnly-";
    return [name hasPrefix:prefix] && FLIsLaunchServicesStoreName([name substringFromIndex:prefix.length]);
}
BOOL FLIsAllowedStoreDirectory(NSString *path) {
    path = FLNormalizeStorePath(path);
    if ([@[@"/private/var/db/lsd", @"/private/var/mobile/Library/Caches"] containsObject:path]) return YES;
    if (![path hasSuffix:@"/Library/Caches"]) return NO;
    NSString *container = [[path stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    if (![FLStoreContainerRoots() containsObject:container.stringByDeletingLastPathComponent]) return NO;
    return [[NSUUID alloc] initWithUUIDString:container.lastPathComponent] != nil ||
        [container.lastPathComponent isEqualToString:@"com.apple.lsd"];
}
NSString *FLCacheDirectoryForResolvedPath(NSString *path) {
    path = FLNormalizeStorePath(path);
    for (NSString *legacy in @[@"/private/var/db/lsd", @"/private/var/mobile/Library/Caches"]) {
        if ([path isEqualToString:legacy] || [path hasPrefix:[legacy stringByAppendingString:@"/"]]) return legacy;
    }
    for (NSString *root in FLStoreContainerRoots()) {
        NSString *prefix = [root stringByAppendingString:@"/"];
        if (![path hasPrefix:prefix]) continue;
        NSString *name = [[path substringFromIndex:prefix.length] componentsSeparatedByString:@"/"].firstObject;
        if (![[NSUUID alloc] initWithUUIDString:name] && ![name isEqualToString:@"com.apple.lsd"]) return nil;
        return [[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Library/Caches"];
    }
    return nil;
}
uint64_t FLInodeStartForCheckpoint(NSDictionary *checkpoint, NSString *context) {
    if (![checkpoint isKindOfClass:NSDictionary.class] || ![checkpoint[@"context"] isEqual:context]) return 16;
    NSNumber *value = [checkpoint[@"next"] isKindOfClass:NSNumber.class] ? checkpoint[@"next"] : nil;
    uint64_t next = value.unsignedLongLongValue;
    return next >= 16 && next < 40000000 && value.doubleValue == (double)next ? next : 16;
}
NSDictionary *FLInodeCheckpoint(NSString *context, uint64_t nextInode) {
    return @{@"context":context, @"next":@(nextInode >= 16 && nextInode < 40000000 ? nextInode : 16)};
}
static NSString *FLAllowedStore(NSString *path) {
    path = FLNormalizeStorePath(path);
    return (FLIsLaunchServicesStoreName(path.lastPathComponent) || FLIsDiagnosticLSStoreName(path.lastPathComponent)) &&
        FLIsAllowedStoreDirectory(path.stringByDeletingLastPathComponent) ? path : nil;
}

@implementation FLStoreDiscovery
+ (NSString *)findStoreUsing:(id<FLStoreDiscoveryAccess>)access group:(NSString *)group
             cachedDirectory:(NSString *)cached extended:(BOOL)extended
                         log:(NSMutableString *)log error:(NSError **)error {
    [log appendFormat:@"Store discovery mode: %@.\n", extended ? @"extended" : @"standard"];
    NSMutableOrderedSet<NSString *> *mapped = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *mappedDiagnostic = [NSMutableOrderedSet orderedSet];
    for (NSString *path in [access mappedStorePathsWithLog:log]) {
        NSString *allowed = FLAllowedStore(path);
        if (allowed) {
            if (FLIsDiagnosticLSStoreName(allowed.lastPathComponent)) [mappedDiagnostic addObject:allowed];
            else [mapped addObject:allowed];
        }
    }
    [log appendFormat:@"Mapped store candidates: %lu.\n", (unsigned long)mapped.count];
    [log appendFormat:@"Mapped prefixed diagnostic stores: %lu; catalog role unverified.\n", (unsigned long)mappedDiagnostic.count];
    NSMutableOrderedSet<NSString *> *directories = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *diagnostic = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    void (^probe)(NSString *) = ^(NSString *directory) {
        directory = FLNormalizeStorePath(directory);
        if (!FLIsAllowedStoreDirectory(directory)) { [log appendFormat:@"Cache directory rejected by path policy: %@.\n", directory]; return; }
        if ([visited containsObject:directory]) return;
        [visited addObject:directory];
        for (NSString *path in [access storePathsInDirectory:directory group:group log:log]) {
            NSString *allowed = FLAllowedStore(path);
            if (!allowed || ![allowed.stringByDeletingLastPathComponent isEqualToString:directory]) continue;
            if (FLIsDiagnosticLSStoreName(allowed.lastPathComponent)) [diagnostic addObject:allowed];
            else if (!mapped.count || [mapped containsObject:allowed]) [candidates addObject:allowed];
        }
    };
    if (mapped.count <= 1) {
        if (mapped.count) {
            [directories addObject:[mapped.firstObject stringByDeletingLastPathComponent]];
        } else {
            for (NSString *path in mappedDiagnostic) [directories addObject:path.stringByDeletingLastPathComponent];
            for (NSNumber *kind in @[@10, @12]) {
                NSString *directory = [access cacheDirectoryForContainerClass:kind.unsignedLongLongValue log:log];
                if (FLIsAllowedStoreDirectory(directory)) [directories addObject:FLNormalizeStorePath(directory)];
            }
            if (FLIsAllowedStoreDirectory(cached)) [directories addObject:FLNormalizeStorePath(cached)];
            // Metadata queries can return nothing in a sandbox. Still try the documented upstream locations.
            [directories addObjectsFromArray:@[@"/private/var/containers/Data/System/com.apple.lsd/Library/Caches",
                                               @"/private/var/mobile/Containers/Data/System/com.apple.lsd/Library/Caches",
                                               @"/private/var/db/lsd", @"/private/var/mobile/Library/Caches"]];
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
                for (NSString *directory in [access inodeCacheDirectoriesWithDeadline:NSProcessInfo.processInfo.systemUptime + 20 log:log]) {
                    if (FLIsAllowedStoreDirectory(directory)) probe(directory);
                }
            }
        } else if (!extended && !candidates.count) {
            [log appendString:@"Extended discovery not run. Use Diagnostics > Extended Store Discovery for bounded container/inode search.\n"];
        }
    }
    if (!mapped.count && !candidates.count && diagnostic.count == 1) {
        [log appendFormat:@"Selected prefixed diagnostic cache: %@. Its catalog role is unverified; profile planning and live writes are disabled. Extended scans continue looking for primary-name stores.\n", diagnostic.firstObject];
        return diagnostic.firstObject;
    }
    if (mapped.count > 1 || candidates.count != 1) {
        NSString *reason = mapped.count > 1 ? @"Multiple mapped stores; the active store is ambiguous."
            : [NSString stringWithFormat:@"Read-only store discovery found %lu primary-name and %lu prefixed diagnostic candidates; an unambiguous source is required.", (unsigned long)candidates.count, (unsigned long)diagnostic.count];
        if (error) *error = [NSError errorWithDomain:@"ForceLegacyUI" code:1
            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@\n%@", reason, log]}];
        return nil;
    }
    [log appendFormat:@"Selected read-only store: %@.\n", candidates.firstObject];
    return candidates.firstObject;
}
@end
