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
uint64_t FLInodeScanUpperBound(uint64_t probeInode) {
    const uint64_t margin = 262144;
    return probeInode >= 16 && probeInode <= UINT64_MAX - margin ? probeInode + margin : 40000000;
}
static BOOL FLInodeNumber(id value, uint64_t minimum, uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    uint64_t number = [value unsignedLongLongValue];
    return number >= minimum && number <= maximum && [value doubleValue] == (double)number;
}
NSArray<NSString *> *FLScanStoreInodes(uint64_t probeInode, NSDictionary *checkpoint, NSString *context,
    NSTimeInterval deadline, NSString *(^resolve)(uint64_t), NSTimeInterval (^now)(void), NSDictionary **nextCheckpoint, NSMutableString *log) {
    const uint64_t recentWindow = 1048576, siblingWindow = 262144;
    uint64_t upper = FLInodeScanUpperBound(probeInode);
    uint64_t recentLower = upper > recentWindow + 16 ? upper - recentWindow + 1 : 16;
    BOOL resume = [checkpoint isKindOfClass:NSDictionary.class] && [checkpoint[@"schema"] isEqual:@2] &&
        [checkpoint[@"context"] isEqual:context] && FLInodeNumber(checkpoint[@"upper"], recentLower, upper) &&
        FLInodeNumber(checkpoint[@"next"], 16, [checkpoint[@"upper"] unsignedLongLongValue]);
    uint64_t olderNext = recentLower - 1;
    if (resume) olderNext = MIN(olderNext, [checkpoint[@"next"] unsignedLongLongValue]);
    uint64_t cursor = upper, examined = 0, resolved = 0, primaryNames = 0, diagnosticNames = 0;
    uint64_t siblingRemaining = 0;
    BOOL recent = YES, timedOut = NO, overflow = NO, siblingLimit = NO;
    NSTimeInterval began = now();
    NSMutableOrderedSet<NSString *> *storeDirectories = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *otherDirectories = [NSMutableOrderedSet orderedSet];
    while (cursor >= 16) {
        if ((examined & 1023) == 0 && now() >= deadline) { timedOut = YES; break; }
        BOOL firstPrimary = NO;
        @autoreleasepool {
            NSString *path = resolve(cursor);
            if (path) {
                ++resolved; path = FLNormalizeStorePath(path);
                NSString *directory = FLCacheDirectoryForResolvedPath(path);
                BOOL primary = FLIsLaunchServicesStoreName(path.lastPathComponent);
                BOOL diagnostic = FLIsDiagnosticLSStoreName(path.lastPathComponent);
                if ((primary || diagnostic) && FLIsAllowedStoreDirectory(path.stringByDeletingLastPathComponent)) {
                    if (primary) { firstPrimary = primaryNames == 0; ++primaryNames; }
                    else ++diagnosticNames;
                    if (primaryNames + diagnosticNames <= 5)
                        [log appendFormat:@"Inode LS filename observation: %@ (path/format/access still must be checked).\n", path];
                    [storeDirectories addObject:path.stringByDeletingLastPathComponent];
                    if (storeDirectories.count > 64) overflow = YES;
                } else if (directory && otherDirectories.count < 64) [otherDirectories addObject:directory];
            }
        }
        ++examined; --cursor;
        if (overflow) break;
        if (firstPrimary) siblingRemaining = siblingWindow;
        else if (siblingRemaining && --siblingRemaining == 0) { siblingLimit = YES; break; }
        if (recent && cursor < recentLower) { recent = NO; cursor = olderNext; }
    }
    NSDictionary *saved = @{@"schema":@2, @"context":context, @"upper":@(upper), @"next":@(cursor >= 16 ? cursor : 0)};
    if (nextCheckpoint) *nextCheckpoint = saved;
    [log appendFormat:@"Inode discovery: descending from %llu (temporary probe %llu; heuristic), %llu inode lookups, %llu decoded paths, %llu primary-name / %llu prefixed LS observations, %.2f seconds.\n",
        (unsigned long long)upper, (unsigned long long)probeInode, (unsigned long long)examined, (unsigned long long)resolved,
        (unsigned long long)primaryNames, (unsigned long long)diagnosticNames, now() - began];
    [log appendFormat:@"Inode outcome: %@; older sweep %@; next %llu. Each run revisits the recent window. Root, name and inode scans do not prove completeness.\n",
        overflow ? @"candidate limit exceeded; refusing scan results" : timedOut ? @"time budget reached" : siblingLimit ? @"bounded primary sibling window reached" : @"heuristic range exhausted",
        resume ? @"resumed" : @"new", (unsigned long long)cursor];
    if (overflow) return @[];
    for (NSString *directory in otherDirectories) {
        if (storeDirectories.count >= 64) break;
        [storeDirectories addObject:directory];
    }
    [log appendFormat:@"Inode cache-directory candidates: %lu (maximum 64; filenames prioritized over other container paths).\n", (unsigned long)storeDirectories.count];
    return storeDirectories.array;
}
int64_t FLVerifiedDirectoryGrant(NSString *directory, int64_t (^request)(BOOL), void (^releaseToken)(int64_t),
    BOOL (^readable)(int *), NSMutableString *log) {
    if (!FLIsAllowedStoreDirectory(directory) && ![FLStoreContainerRoots() containsObject:FLNormalizeStorePath(directory)]) return -100;
    int64_t last = -1;
    for (unsigned attempt = 0; attempt < 2; ++attempt) {
        BOOL alternate = attempt == 1;
        int64_t token = request(alternate); last = token;
        if (token >= 0) {
            int failure = 0;
            if (readable(&failure)) {
                [log appendFormat:@"Grant %@: %@ flags, handle %lld; read-only directory probe succeeded.\n", directory, alternate ? @"alternate" : @"standard", (long long)token];
                return token;
            }
            releaseToken(token); last = -8;
            [log appendFormat:@"Grant %@: %@ handle %lld released; directory probe failed, errno %d.\n", directory, alternate ? @"alternate" : @"standard", (long long)token, failure];
        } else {
            [log appendFormat:@"Grant %@: %@ query returned %lld; no usable token.\n", directory, alternate ? @"alternate" : @"standard", (long long)token];
            if (token == -2) break;
        }
    }
    return last;
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
