// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <mach-o/loader.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *FLArchitectureForMachHeader(const struct mach_header * _Nullable header);
NS_ASSUME_NONNULL_END
