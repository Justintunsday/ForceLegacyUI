// SPDX-License-Identifier: GPL-3.0-or-later
#import "FLLSBridge.h"
#import "worse_query.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/fsgetpath.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <xpc/xpc.h>

static NSError *FLError(NSString *message) {
    return [NSError errorWithDomain:@"ForceLegacyUI" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static void FLLoadServices(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY | RTLD_LOCAL);
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
    });
}
static id FLValue(id object, NSString *key) {
    @try { return [object respondsToSelector:NSSelectorFromString(key)] ? [object valueForKey:key] : nil; }
    @catch (NSException *exception) { return nil; }
}
static NSString *FLString(id object) { return [object isKindOfClass:NSString.class] ? object : @""; }
static NSString *FLNormalize(NSString *path) {
    if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
    return path.stringByStandardizingPath;
}
static id FLWorkspace(void) {
    FLLoadServices();
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    SEL selector = NSSelectorFromString(@"defaultWorkspace");
    if (![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}
NSArray<NSDictionary<NSString *, id> *> *FLInstalledApps(NSString **diagnostics) {
    NSMutableArray *result = [NSMutableArray array];
    @try {
        id workspace = FLWorkspace();
        id proxies = FLValue(workspace, @"allInstalledApplications");
        if (![proxies isKindOfClass:NSArray.class]) {
            if (diagnostics) *diagnostics = @"LSApplicationWorkspace did not expose the installed application list. Visibility may be restricted by signing or OS policy.";
            return result;
        }
        NSMutableSet *seen = [NSMutableSet set];
        for (id proxy in proxies) {
            NSString *identifier = FLString(FLValue(proxy, @"applicationIdentifier"));
            if (!identifier.length) identifier = FLString(FLValue(proxy, @"bundleIdentifier"));
            id bundleURL = FLValue(proxy, @"bundleURL");
            if (!identifier.length || ![bundleURL isKindOfClass:NSURL.class] || [seen containsObject:identifier]) continue;
            [seen addObject:identifier];
            NSString *name = FLString(FLValue(proxy, @"localizedName"));
            [result addObject:@{@"bundleID":identifier, @"name":name.length ? name : identifier,
                @"bundlePath":FLNormalize([bundleURL path]), @"sdk":FLString(FLValue(proxy, @"sdkVersion")),
                @"applicationType":FLString(FLValue(proxy, @"applicationType"))}];
        }
        if (diagnostics) *diagnostics = [NSString stringWithFormat:@"LSApplicationWorkspace returned %lu visible apps. Completeness is not guaranteed. SDK values are registration metadata, not observed appearance.", (unsigned long)result.count];
    } @catch (NSException *exception) {
        if (diagnostics) *diagnostics = [NSString stringWithFormat:@"LaunchServices exception: %@", exception.name];
    }
    return result;
}
static NSString *FLSysctl(const char *key) {
    char buffer[256] = {0}; size_t size = sizeof(buffer);
    if (sysctlbyname(key, buffer, &size, NULL, 0) != 0) return @"unknown";
    return [NSString stringWithUTF8String:buffer] ?: @"unknown";
}
NSDictionary<NSString *, NSString *> *FLDeviceInfo(void) {
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    struct utsname info; memset(&info, 0, sizeof(info)); uname(&info);
    NSString *build = FLSysctl("kern.osversion");
#if TARGET_OS_SIMULATOR
    build = [@"simulator-host-kernel:" stringByAppendingString:build];
    NSString *environment = @"simulator";
#else
    NSString *environment = @"physical-device";
#endif
    return @{@"osVersion":[NSString stringWithFormat:@"%ld.%ld.%ld", (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion],
             @"osBuild":build, @"environment":environment, @"model":FLSysctl("hw.machine"),
             @"architecture":[NSString stringWithUTF8String:info.machine] ?: @"unknown"};
}
UIImage *FLApplicationIcon(NSString *bundleID) {
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![UIImage respondsToSelector:sel]) return nil;
    @try {
        id value = ((id (*)(id, SEL, NSString *, NSInteger, CGFloat))objc_msgSend)(UIImage.class, sel, bundleID, 2, UIScreen.mainScreen.scale);
        return [value isKindOfClass:UIImage.class] ? value : nil;
    } @catch (NSException *exception) { return nil; }
}
NSDictionary<NSString *, id> *FLProbeFacts(void) {
    NSMutableDictionary *facts = [NSMutableDictionary dictionaryWithDictionary:FLDeviceInfo()];
    NSBundle *bundle = NSBundle.mainBundle;
    facts[@"bundleID"] = bundle.bundleIdentifier ?: @"unknown";
    facts[@"plistCompatibilityValue"] = [bundle objectForInfoDictionaryKey:@"UIDesignRequiresCompatibility"] ?: @"absent";
    facts[@"DTSDKName"] = [bundle objectForInfoDictionaryKey:@"DTSDKName"] ?: @"absent";
    facts[@"appearanceVerified"] = @NO;
    uint32_t (*sdkVersion)(void) = dlsym(RTLD_DEFAULT, "dyld_get_program_sdk_version");
    if (sdkVersion) {
        uint32_t value = sdkVersion();
        facts[@"dyldSDK"] = [NSString stringWithFormat:@"%u.%u.%u", value >> 16, (value >> 8) & 255, value & 255];
    }
    const struct mach_header *header = _dyld_get_image_header(0);
    if (header && header->magic == MH_MAGIC_64 && header->sizeofcmds <= 1024 * 1024 && header->ncmds <= 4096) {
        const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
        const uint8_t *end = cursor + header->sizeofcmds;
        for (uint32_t i = 0; i < header->ncmds && (size_t)(end - cursor) >= sizeof(struct load_command); ++i) {
            struct load_command command; memcpy(&command, cursor, sizeof(command));
            if (command.cmdsize < sizeof(command) || command.cmdsize > (size_t)(end - cursor)) break;
            if (command.cmd == LC_BUILD_VERSION && command.cmdsize >= sizeof(struct build_version_command)) {
                struct build_version_command build; memcpy(&build, cursor, sizeof(build));
                facts[@"machOSDK"] = [NSString stringWithFormat:@"%u.%u.%u", build.sdk >> 16, (build.sdk >> 8) & 255, build.sdk & 255];
                facts[@"machOMinOS"] = [NSString stringWithFormat:@"%u.%u.%u", build.minos >> 16, (build.minos >> 8) & 255, build.minos & 255];
            }
            cursor += command.cmdsize;
        }
    }
    FLLoadServices();
    Class proxy = NSClassFromString(@"LSApplicationProxy"); SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if ([proxy respondsToSelector:sel]) {
        @try {
            id app = ((id (*)(id, SEL, NSString *))objc_msgSend)(proxy, sel, bundle.bundleIdentifier);
            facts[@"launchServicesSDK"] = FLString(FLValue(app, @"sdkVersion"));
        } @catch (NSException *exception) { facts[@"launchServicesError"] = exception.name; }
    }
    return facts;
}

BOOL FLCSStoreValidate(NSString *path, NSNumber **calculatedChecksum, NSError **error) {
    static void *handle; static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = dlopen("/System/Library/PrivateFrameworks/CoreServicesStore.framework/CoreServicesStore", RTLD_LAZY | RTLD_LOCAL); });
    id (*openStore)(NSURL *, NSError **) = handle ? dlsym(handle, "_CSStoreCreateWithURL") : NULL;
    if (!openStore) { if (error) *error = FLError(@"CoreServicesStore validation is unavailable on this OS."); return NO; }
    NSError *failure = nil;
    @try {
        id store = openStore([NSURL fileURLWithPath:path], &failure);
        if (store) return YES;
    } @catch (NSException *exception) { failure = FLError([@"CoreServicesStore exception: " stringByAppendingString:exception.name]); }
    id sum = failure.userInfo[@"CalculatedChecksum"];
    if ([sum isKindOfClass:NSNumber.class] && [sum longLongValue] >= 0 && [sum unsignedLongLongValue] <= UINT16_MAX) {
        if (calculatedChecksum) *calculatedChecksum = sum;
    }
    if (error) *error = failure ?: FLError(@"CoreServicesStore rejected the copy without a usable checksum.");
    return NO;
}

static BOOL FLIsStoreName(NSString *name) {
    return [name hasPrefix:@"com.apple.LaunchServices-"] && [name hasSuffix:@"-v2.csstore"] && [name.lastPathComponent isEqualToString:name];
}
static BOOL FLIsCacheDirectory(NSString *path) {
    path = FLNormalize(path);
    if (![path hasSuffix:@"/Library/Caches"]) return NO;
    NSString *container = [[path stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSString *root = container.stringByDeletingLastPathComponent;
    if (!([root isEqualToString:@"/private/var/mobile/Containers/Data/InternalDaemon"] ||
          [root isEqualToString:@"/private/var/containers/Data/System"])) return NO;
    return [[NSUUID alloc] initWithUUIDString:container.lastPathComponent] != nil || [container.lastPathComponent isEqualToString:@"com.apple.lsd"];
}
static NSArray<NSString *> *FLMappedStores(void) {
    (void)FLInstalledApps(NULL); // Causes LaunchServices to map its client database where permitted.
    int (*filename)(int, uint64_t, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_regionfilename");
    if (!filename) return @[];
    NSMutableOrderedSet *paths = [NSMutableOrderedSet orderedSet];
    vm_address_t address = 0;
    for (unsigned i = 0; i < 16384; ++i) {
        vm_size_t size = 0; vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t object = MACH_PORT_NULL;
        kern_return_t status = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (status != KERN_SUCCESS || size == 0 || UINTPTR_MAX - address < size) break;
        char buffer[PATH_MAX] = {0};
        if (filename(getpid(), address, buffer, sizeof(buffer)) > 0) {
            NSString *path = FLNormalize([NSString stringWithUTF8String:buffer] ?: @"");
            if (FLIsStoreName(path.lastPathComponent) && FLIsCacheDirectory(path.stringByDeletingLastPathComponent)) [paths addObject:path];
        }
        address += size;
    }
    return paths.array;
}
static NSString *FLContainerDirectory(uint64_t kind) {
    void *lib = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!lib) return nil;
    void *(*create)(void) = dlsym(lib, "container_query_create");
    void (*setClass)(void *, uint64_t) = dlsym(lib, "container_query_set_class");
    void (*setIDs)(void *, xpc_object_t) = dlsym(lib, "container_query_set_identifiers");
    void (*setFlags)(void *, uint64_t) = dlsym(lib, "container_query_operation_set_flags");
    void *(*getOne)(void *) = dlsym(lib, "container_query_get_single_result");
    const char *(*getPath)(void *) = dlsym(lib, "container_object_get_path");
    void (*freeQuery)(void *) = dlsym(lib, "container_query_free");
    NSString *path = nil;
    if (create && setClass && setIDs && setFlags && getOne && getPath && freeQuery) {
        void *query = create();
        if (query) {
            setClass(query, kind); setIDs(query, xpc_string_create("com.apple.lsd")); setFlags(query, 0x100000000ULL);
            void *result = getOne(query); const char *raw = result ? getPath(result) : NULL;
            if (raw) path = [FLNormalize([NSString stringWithUTF8String:raw]) stringByAppendingPathComponent:@"Library/Caches"];
            freeQuery(query);
        }
    }
    dlclose(lib); return FLIsCacheDirectory(path) ? path : nil;
}
static NSArray<NSString *> *FLExtendedDiscovery(void) {
    struct statfs volume;
    if (statfs(NSHomeDirectory().fileSystemRepresentation, &volume) != 0) return @[];
    NSMutableOrderedSet *paths = [NSMutableOrderedSet orderedSet];
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    for (uint64_t inode = 16; inode < 40000000; ++inode) {
        if ((inode & 1023) == 0 && NSProcessInfo.processInfo.systemUptime - start > 8) break;
        char buffer[PATH_MAX] = {0};
        if (fsgetpath(buffer, sizeof(buffer), &volume.f_fsid, inode) <= 0) continue;
        if (!strstr(buffer, "LaunchServices-") || !strstr(buffer, "-v2.csstore")) continue;
        NSString *path = FLNormalize([NSString stringWithUTF8String:buffer] ?: @"");
        if (FLIsStoreName(path.lastPathComponent) && FLIsCacheDirectory(path.stringByDeletingLastPathComponent)) [paths addObject:path];
    }
    return paths.array;
}
@interface FLStoreSession ()
@property (nonatomic, readwrite, copy) NSString *path;
@property (nonatomic, readwrite, copy) NSString *diagnostics;
@property (nonatomic) int64_t token;
@end
@implementation FLStoreSession
- (instancetype)init { if ((self = [super init])) _token = -1; return self; }
- (void)endAccess { if (_token >= 0) { worse_query_release(_token); _token = -1; } }
- (void)dealloc { [self endAccess]; }
@end

FLStoreSession *FLOpenStore(NSString *group, NSString *cachedDirectory, BOOL extendedSearch, NSError **error) {
#if TARGET_OS_SIMULATOR
    if (error) *error = FLError(@"Sandbox-extension research requires a physical device. Use Demo laboratory in the simulator.");
    return nil;
#else
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    if (version.majorVersion != 26 || version.minorVersion > 7 || (version.minorVersion == 7 && version.patchVersion > 2)) {
        if (error) *error = FLError(@"This OS is outside the upstream-reported iOS 26.0–26.7.2 access range. Read-only app listing is still available.");
        return nil;
    }
    if (group.length == 0 || ![NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group]) {
        if (error) *error = FLError(@"A provisioned, dedicated App Group is required. Set FLAppGroupIdentifier and sign with matching application-groups entitlement.");
        return nil;
    }
    NSMutableString *log = [NSMutableString string];
    NSArray *mapped = FLMappedStores();
    [log appendFormat:@"Mapped store candidates: %lu.\n", (unsigned long)mapped.count];
    if (mapped.count > 1) { if (error) *error = FLError(@"Multiple mapped stores; active store is ambiguous. Nothing opened for writing."); return nil; }
    NSMutableOrderedSet *directories = [NSMutableOrderedSet orderedSet];
    for (NSString *path in mapped) [directories addObject:[path stringByDeletingLastPathComponent]];
    if (mapped.count == 0) {
        for (NSNumber *kind in @[@10, @12]) {
            NSString *directory = FLContainerDirectory(kind.unsignedLongLongValue);
            if (directory) [directories addObject:directory];
        }
        if (FLIsCacheDirectory(cachedDirectory)) [directories addObject:FLNormalize(cachedDirectory)];
        if (extendedSearch) for (NSString *path in FLExtendedDiscovery()) [directories addObject:path.stringByDeletingLastPathComponent];
    }
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *directory in directories) {
        // Upstream's create_dir argument only skips the pre-grant lstat; the target is never created here.
        int64_t token = worse_query(directory, group, false, true);
        if (token < 0) token = worse_query(directory, group, true, true);
        [log appendFormat:@"Grant %@: %lld\n", directory, token];
        if (token < 0) continue;
        NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil];
        for (NSString *name in names) {
            if (!FLIsStoreName(name)) continue;
            NSString *path = [directory stringByAppendingPathComponent:name]; struct stat st;
            if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode) && st.st_nlink == 1 &&
                st.st_size >= 100 && st.st_size <= 64 * 1024 * 1024 &&
                (mapped.count == 0 || [mapped containsObject:path])) [candidates addObject:path];
        }
        worse_query_release(token);
    }
    NSOrderedSet *unique = [NSOrderedSet orderedSetWithArray:candidates];
    if (unique.count != 1) {
        if (error) *error = FLError([NSString stringWithFormat:@"Read-only store discovery found %lu unambiguous candidates; exactly one is required.\n%@", (unsigned long)unique.count, log]);
        return nil;
    }
    NSString *path = unique.firstObject, *directory = path.stringByDeletingLastPathComponent;
    int64_t token = worse_query(directory, group, false, true);
    if (token < 0) token = worse_query(directory, group, true, true);
    if (token < 0) { if (error) *error = FLError(@"Could not reacquire the selected directory extension."); return nil; }
    FLStoreSession *session = [FLStoreSession new]; session.path = path; session.token = token; session.diagnostics = log;
    return session;
#endif
}
