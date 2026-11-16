// SPDX-License-Identifier: GPL-3.0-or-later
#import "FLBundleEvidence.h"
#import "FLStoreDiscovery.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSError *FLBundleError(NSString *message) {
    return [NSError errorWithDomain:@"ForceLegacyUI.BundleEvidence" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL FLFail(NSError **error, NSString *message) { if (error) *error = FLBundleError(message); return NO; }
BOOL FLIsApplicationBundlePath(NSString *path) {
    NSData *encoded = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (!encoded || memchr(encoded.bytes, 0, encoded.length)) return NO;
    path = FLNormalizeStorePath(path);
    NSString *parent = path.stringByDeletingLastPathComponent;
    return [path.pathExtension isEqualToString:@"app"] && path.lastPathComponent.length > 4 &&
        [[NSUUID alloc] initWithUUIDString:parent.lastPathComponent] != nil &&
        [parent.stringByDeletingLastPathComponent isEqualToString:@"/private/var/containers/Bundle/Application"];
}
static uint32_t FLLE32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
static uint32_t FLBE32(const uint8_t *p) { return (uint32_t)p[3] | (uint32_t)p[2]<<8 | (uint32_t)p[1]<<16 | (uint32_t)p[0]<<24; }
static uint64_t FLBE64(const uint8_t *p) { return (uint64_t)FLBE32(p)<<32 | FLBE32(p+4); }
typedef NSData * _Nullable (^FLReadRange)(uint64_t, NSUInteger);
static NSDictionary *FLMachOObservation(uint64_t fileSize, FLReadRange read, NSError **error) {
    NSData *prefix = fileSize >= 8 ? read(0, 8) : nil;
    if (!prefix) { FLFail(error, @"Executable header is truncated or unreadable."); return nil; }
    const uint8_t *p = prefix.bytes;
    NSMutableArray<NSArray<NSNumber *> *> *slices = [NSMutableArray array];
    NSMutableData *headers = [NSMutableData dataWithData:prefix];
    uint32_t fatMagic = FLBE32(p);
    if (fatMagic == FAT_MAGIC || fatMagic == FAT_MAGIC_64) {
        uint32_t count = FLBE32(p+4), width = fatMagic == FAT_MAGIC_64 ? 32 : 20;
        if (count == 0 || count > 32 || fileSize < 8 + (uint64_t)count * width) { FLFail(error, @"Invalid universal executable table."); return nil; }
        NSData *arches = read(8, count * width);
        if (!arches) { FLFail(error, @"Universal executable table could not be read."); return nil; }
        [headers appendData:arches];
        const uint8_t *a = arches.bytes;
        for (uint32_t index = 0; index < count; ++index) {
            const uint8_t *entry = a + index * width;
            if (FLBE32(entry) != CPU_TYPE_ARM64) continue;
            uint64_t start = width == 32 ? FLBE64(entry+8) : FLBE32(entry+8);
            uint64_t size = width == 32 ? FLBE64(entry+16) : FLBE32(entry+12);
            if (start < 8 + count * width || start > fileSize || size > fileSize - start) { FLFail(error, @"Universal slice is out of bounds."); return nil; }
            [slices addObject:@[@(start), @(size)]];
        }
    } else [slices addObject:@[@0, @(fileSize)]];
    if (!slices.count) { FLFail(error, @"No arm64 executable slice was found."); return nil; }
    NSString *sdkText = nil;
    for (NSArray<NSNumber *> *slice in slices) {
        uint64_t start = slice[0].unsignedLongLongValue, size = slice[1].unsignedLongLongValue;
        NSData *head = size >= 32 ? read(start, 32) : nil;
        if (!head) { FLFail(error, @"Mach-O header could not be read."); return nil; }
        const uint8_t *h = head.bytes;
        uint32_t count = FLLE32(h+16), bytes = FLLE32(h+20);
        if (FLLE32(h) != MH_MAGIC_64 || FLLE32(h+4) != CPU_TYPE_ARM64 || FLLE32(h+12) != MH_EXECUTE ||
            count == 0 || count > 4096 || bytes > 1024*1024 || size < 32 || bytes > size-32) {
            FLFail(error, @"Unsupported or out-of-bounds executable load commands."); return nil;
        }
        NSData *commands = read(start+32, bytes);
        if (!commands) { FLFail(error, @"Executable load commands could not be read."); return nil; }
        [headers appendData:head]; [headers appendData:commands];
        const uint8_t *c = commands.bytes; NSUInteger cursor = 0; uint32_t sdk = 0;
        for (uint32_t index = 0; index < count; ++index) {
            if (cursor > bytes || bytes-cursor < 8) { FLFail(error, @"Truncated executable command."); return nil; }
            uint32_t kind = FLLE32(c+cursor), length = FLLE32(c+cursor+4), value = 0;
            if (length < 8 || length % 8 != 0 || length > bytes-cursor) { FLFail(error, @"Invalid executable command size."); return nil; }
            if (kind == LC_BUILD_VERSION) {
                if (length < 24 || FLLE32(c+cursor+8) != PLATFORM_IOS) { FLFail(error, @"Executable is not an iOS device build."); return nil; }
                value = FLLE32(c+cursor+16);
                uint32_t tools = FLLE32(c+cursor+20);
                if (tools > (length-24)/8) { FLFail(error, @"Build-tool commands exceed their bounds."); return nil; }
            } else if (kind == LC_VERSION_MIN_IPHONEOS) {
                if (length < 16) { FLFail(error, @"Truncated iOS version command."); return nil; }
                value = FLLE32(c+cursor+12);
            }
            if (value) {
                if (sdk && sdk != value) { FLFail(error, @"Executable SDK commands disagree."); return nil; }
                sdk = value;
            }
            cursor += length;
        }
        if (cursor != bytes || !sdk || sdk>>16 == 0 || sdk>>16 > 99 || ((sdk>>8)&255) > 99 || (sdk&255) > 99) {
            FLFail(error, @"No unambiguous executable SDK was found."); return nil;
        }
        NSString *value = [NSString stringWithFormat:@"%u.%u.%u", sdk>>16, (sdk>>8)&255, sdk&255];
        if (sdkText && ![sdkText isEqualToString:value]) { FLFail(error, @"Arm64 slices have different build SDKs."); return nil; }
        sdkText = value;
    }
    return @{@"sdk":sdkText, @"loadCommands":headers};
}
static NSData *FLReadFD(int descriptor, uint64_t size, uint64_t offset, NSUInteger count) {
    if (count > 1024*1024 || offset > size || count > size-offset) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:count]; uint8_t *bytes = data.mutableBytes; NSUInteger done = 0;
    while (done < count) {
        ssize_t value = pread(descriptor, bytes+done, count-done, (off_t)(offset+done));
        if (value < 0 && errno == EINTR) continue;
        if (value <= 0) return nil;
        done += (NSUInteger)value;
    }
    return data;
}
static BOOL FLUnchangedFile(int directory, NSString *name, int descriptor, const struct stat *before) {
    struct stat after, path;
    return fstat(descriptor, &after) == 0 && fstatat(directory, name.fileSystemRepresentation, &path, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISREG(after.st_mode) && S_ISREG(path.st_mode) && after.st_nlink == 1 && after.st_dev == before->st_dev &&
        after.st_ino == before->st_ino && path.st_dev == after.st_dev && path.st_ino == after.st_ino &&
        after.st_size == before->st_size && after.st_mtimespec.tv_sec == before->st_mtimespec.tv_sec &&
        after.st_mtimespec.tv_nsec == before->st_mtimespec.tv_nsec;
}
static NSDictionary *FLReadBundleAtFD(int directory, NSString *identifier, NSError **error) {
    int infoFD = -1, executableFD = -1;
    @try {
        struct stat infoStat, executableStat;
        infoFD = openat(directory, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (infoFD < 0 || fstat(infoFD, &infoStat) != 0 || !S_ISREG(infoStat.st_mode) || infoStat.st_nlink != 1 ||
            infoStat.st_size <= 0 || infoStat.st_size > 1024*1024) { FLFail(error, @"Bundle Info.plist is unreadable or outside the size/type policy."); return nil; }
        NSData *infoData = FLReadFD(infoFD, (uint64_t)infoStat.st_size, 0, (NSUInteger)infoStat.st_size);
        id info = infoData ? [NSPropertyListSerialization propertyListWithData:infoData options:NSPropertyListImmutable format:NULL error:NULL] : nil;
        if (![info isKindOfClass:NSDictionary.class] || ![info[@"CFBundleIdentifier"] isEqual:identifier]) { FLFail(error, @"Bundle identifier does not match the cache registration."); return nil; }
        NSString *executable = info[@"CFBundleExecutable"];
        if (![executable isKindOfClass:NSString.class] || !executable.length || executable.length > 255 ||
            ![executable.lastPathComponent isEqual:executable] || [@[@".", @".."] containsObject:executable] ||
            [executable rangeOfString:@"\\"].location != NSNotFound) { FLFail(error, @"Invalid bundle executable name."); return nil; }
        NSData *nameBytes = [executable dataUsingEncoding:NSUTF8StringEncoding];
        if (!nameBytes || memchr(nameBytes.bytes, 0, nameBytes.length)) { FLFail(error, @"Invalid executable filename encoding."); return nil; }
        executableFD = openat(directory, executable.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (executableFD < 0 || fstat(executableFD, &executableStat) != 0 || !S_ISREG(executableStat.st_mode) ||
            executableStat.st_nlink != 1 || executableStat.st_size <= 0) { FLFail(error, @"Bundle executable is not a readable regular file."); return nil; }
        NSDictionary *observed = FLMachOObservation((uint64_t)executableStat.st_size, ^NSData *(uint64_t offset, NSUInteger length) {
            return FLReadFD(executableFD, (uint64_t)executableStat.st_size, offset, length);
        }, error);
        if (!observed) return nil;
        if (!FLUnchangedFile(directory, @"Info.plist", infoFD, &infoStat) || !FLUnchangedFile(directory, executable, executableFD, &executableStat)) {
            FLFail(error, @"Bundle metadata changed during observation."); return nil;
        }
        return @{@"sdk":observed[@"sdk"], @"infoData":infoData, @"loadCommands":observed[@"loadCommands"]};
    } @finally { if (infoFD >= 0) close(infoFD); if (executableFD >= 0) close(executableFD); }
}
NSDictionary<NSString *, id> *FLReadBundleEvidence(NSString *identifier, NSString *path,
    int64_t (^requestToken)(BOOL), void (^releaseToken)(int64_t), NSError **error) {
    if (!identifier.length || identifier.length > 255 || !FLIsApplicationBundlePath(path)) { FLFail(error, @"Bundle metadata request is outside the application-bundle policy."); return nil; }
    path = FLNormalizeStorePath(path); int directory = -1; int64_t token = -1;
    @try {
        directory = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (directory < 0 && requestToken && releaseToken) {
            for (unsigned attempt = 0; attempt < 2; ++attempt) {
                token = requestToken(attempt == 1);
                if (token >= 0) {
                    directory = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                    if (directory >= 0) break;
                    releaseToken(token); token = -1;
                } else if (token == -2) break;
            }
        }
        if (directory < 0) { FLFail(error, [NSString stringWithFormat:@"Application bundle could not be opened read-only (errno %d).", errno]); return nil; }
        char resolved[PATH_MAX];
        if (!realpath(path.fileSystemRepresentation, resolved) || ![FLNormalizeStorePath([NSString stringWithUTF8String:resolved]) isEqualToString:path]) {
            FLFail(error, @"Application bundle contains a path alias or could not be resolved."); return nil;
        }
        return FLReadBundleAtFD(directory, identifier, error);
    } @finally { if (directory >= 0) close(directory); if (token >= 0 && releaseToken) releaseToken(token); }
}
#if defined(FL_CONTAINER_TESTING)
NSDictionary<NSString *, id> *FLTestBundleAtFD(int directory, NSString *identifier, NSError **error) { return FLReadBundleAtFD(directory, identifier, error); }
NSDictionary<NSString *, id> *FLTestMachOObservation(NSData *data, NSError **error) {
    return FLMachOObservation(data.length, ^NSData *(uint64_t offset, NSUInteger count) {
        if (offset > data.length || count > data.length-offset) return nil;
        return [data subdataWithRange:NSMakeRange((NSUInteger)offset, count)];
    }, error);
}
#endif
