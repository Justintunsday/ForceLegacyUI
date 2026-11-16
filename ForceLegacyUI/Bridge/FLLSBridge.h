#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *FLInstalledApps(NSString * _Nullable * _Nullable diagnostics);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *FLDeviceInfo(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *FLProbeFacts(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *FLAppGroupContext(void);
FOUNDATION_EXPORT NSString *FLAccessMode(void);
FOUNDATION_EXPORT void FLResetStoreDiscoveryProgress(void);
FOUNDATION_EXPORT UIImage * _Nullable FLApplicationIcon(NSString *bundleID);
FOUNDATION_EXPORT BOOL FLCSStoreValidate(NSString *path, NSNumber * _Nullable * _Nullable calculatedChecksum, NSError * _Nullable * _Nullable error) __attribute__((swift_error(none)));

@interface FLStoreSession : NSObject
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *diagnostics;
- (void)endAccess;
@end
FOUNDATION_EXPORT FLStoreSession * _Nullable FLOpenStore(NSString *group, NSString * _Nullable cachedDirectory,
                                                       BOOL extendedSearch, NSError * _Nullable * _Nullable error) __attribute__((swift_error(none)));
NS_ASSUME_NONNULL_END
