// SPDX-License-Identifier: GPL-3.0-or-later
#import "FLDeviceIdentity.h"

NSString *FLArchitectureForMachHeader(const struct mach_header *header) {
    if (!header || (header->magic != MH_MAGIC && header->magic != MH_MAGIC_64)) return @"unknown";
    if (header->cputype == CPU_TYPE_ARM64) {
        uint32_t subtype = (uint32_t)header->cpusubtype & ~(uint32_t)CPU_SUBTYPE_MASK;
        return subtype == CPU_SUBTYPE_ARM64E ? @"arm64e" : @"arm64";
    }
    if (header->cputype == CPU_TYPE_X86_64) return @"x86_64";
    return @"unknown";
}
