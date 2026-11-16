// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL FLIsApplicationBundlePath(NSString *path);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable FLReadBundleEvidence(NSString *identifier, NSString *path,
    int64_t (^ _Nullable requestToken)(BOOL), void (^ _Nullable releaseToken)(int64_t), NSError * _Nullable * _Nullable error);
#if defined(FL_CONTAINER_TESTING)
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable FLTestMachOObservation(NSData *data, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable FLTestBundleAtFD(int directory, NSString *identifier, NSError * _Nullable * _Nullable error);
#endif
NS_ASSUME_NONNULL_END
