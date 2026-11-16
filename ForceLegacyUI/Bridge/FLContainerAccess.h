// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL FLHouseArrestIdentityAllowed(NSString *bundleID, NSString *mode);
FOUNDATION_EXPORT NSString * _Nullable FLTraversalDomainForCacheDirectory(NSString *directory);
FOUNDATION_EXPORT int64_t FLTraversalTokenForCacheDirectory(NSString *directory, NSMutableString *log);
FOUNDATION_EXPORT NSString *FLContainerRuntimeDiagnostics(void);
FOUNDATION_EXPORT void FLReleaseDirectoryToken(int64_t token);
FOUNDATION_EXPORT BOOL FLCanReleaseDirectoryTokens(void);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *FLMHAAppDataCatalog(NSMutableString *log);

/// Holds only a com.apple.lsd query/extension for the lifetime of a read-only session.
@interface FLLSDContainerLease : NSObject
@property (nonatomic, readonly, copy) NSString *cacheDirectory;
+ (nullable instancetype)openForClass:(uint64_t)kind log:(NSMutableString *)log;
@end
NS_ASSUME_NONNULL_END
