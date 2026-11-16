// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *FLNormalizeStorePath(NSString * _Nullable path);
FOUNDATION_EXPORT BOOL FLIsAllowedStoreDirectory(NSString * _Nullable path);
FOUNDATION_EXPORT BOOL FLIsLaunchServicesStoreName(NSString *name);
FOUNDATION_EXPORT BOOL FLIsDiagnosticLSStoreName(NSString *name);
FOUNDATION_EXPORT NSArray<NSString *> *FLStoreContainerRoots(void);
FOUNDATION_EXPORT NSString * _Nullable FLCacheDirectoryForResolvedPath(NSString *path);
FOUNDATION_EXPORT uint64_t FLInodeScanUpperBound(uint64_t probeInode);
/// A recent-inode heuristic, then a resumable older sweep. Neither proves completeness.
FOUNDATION_EXPORT NSArray<NSString *> *FLScanStoreInodes(uint64_t probeInode, NSDictionary * _Nullable checkpoint,
    NSString *context, NSTimeInterval deadline, NSString * _Nullable (^resolve)(uint64_t), NSTimeInterval (^now)(void),
    NSDictionary * _Nullable * _Nullable nextCheckpoint, NSMutableString *log);
/// A consumed token is retained only when an actual read-only directory probe succeeds.
FOUNDATION_EXPORT int64_t FLVerifiedDirectoryGrant(NSString *directory, int64_t (^request)(BOOL alternate),
    void (^releaseToken)(int64_t), BOOL (^readable)(int *failure), NSMutableString *log);

/// Discovery policy is separate from private APIs so denied/empty responses can be tested.
/// Implementations only list directory names and read metadata for matching cache files.
@protocol FLStoreDiscoveryAccess <NSObject>
- (NSArray<NSString *> *)mappedStorePathsWithLog:(NSMutableString *)log;
- (nullable NSString *)cacheDirectoryForContainerClass:(uint64_t)kind log:(NSMutableString *)log;
- (NSArray<NSString *> *)storePathsInDirectory:(NSString *)directory group:(NSString *)group log:(NSMutableString *)log;
- (NSArray<NSString *> *)cacheDirectoriesInRoot:(NSString *)root group:(NSString *)group
                                      deadline:(NSTimeInterval)deadline log:(NSMutableString *)log;
- (NSArray<NSString *> *)inodeCacheDirectoriesWithDeadline:(NSTimeInterval)deadline log:(NSMutableString *)log;
@end

@interface FLStoreDiscovery : NSObject
+ (nullable NSString *)findStoreUsing:(id<FLStoreDiscoveryAccess>)access group:(NSString *)group
                      cachedDirectory:(nullable NSString *)cached extended:(BOOL)extended
                                  log:(NSMutableString *)log error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
