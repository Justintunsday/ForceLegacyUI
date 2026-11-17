// SPDX-License-Identifier: GPL-3.0-or-later
#import "FLLSBridge.h"
#import "FLStoreDiscovery.h"
#import "FLDeviceIdentity.h"
#import "FLContainerAccess.h"
#import "FLBundleEvidence.h"
#import "worse_query.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/fsgetpath.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
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
NSString *FLAccessMode(void) {
    return FLString([NSBundle.mainBundle objectForInfoDictionaryKey:@"FLAccessMode"]);
}
NSDictionary<NSString *, id> *FLInspectBundle(NSString *identifier, NSString *path, NSString *group, NSError **error) {
    if (!FLIsApplicationBundlePath(path)) return FLReadBundleEvidence(identifier, path, nil, nil, error);
    NSString *readPath = FLNormalizeStorePath(path);
    // Bulk enumeration can be empty while an individual proxy still provides the on-disk spelling.
    // It is only a hint: keep the same UUID/name and require the native Info/Mach-O read below.
    FLLoadServices();
    Class proxyClass = NSClassFromString(@"LSApplicationProxy"); SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if ([proxyClass respondsToSelector:lookup]) {
        @try {
            id proxy = ((id (*)(id, SEL, NSString *))objc_msgSend)(proxyClass, lookup, identifier);
            NSString *returnedID = FLString(FLValue(proxy, @"applicationIdentifier"));
            if (!returnedID.length) returnedID = FLString(FLValue(proxy, @"bundleIdentifier"));
            id url = FLValue(proxy, @"bundleURL");
            NSString *candidate = [url isKindOfClass:NSURL.class] && [url isFileURL] ? FLNormalizeStorePath([url path]) : @"";
            NSUUID *expected = [[NSUUID alloc] initWithUUIDString:readPath.stringByDeletingLastPathComponent.lastPathComponent];
            NSUUID *reported = [[NSUUID alloc] initWithUUIDString:candidate.stringByDeletingLastPathComponent.lastPathComponent];
            if ([returnedID isEqual:identifier] && FLIsApplicationBundlePath(candidate) && [expected isEqual:reported] &&
                [readPath.lastPathComponent caseInsensitiveCompare:candidate.lastPathComponent] == NSOrderedSame) readPath = candidate;
        } @catch (NSException *exception) { (void)exception; }
    }
    BOOL useGroup = group.length && FLCanReleaseDirectoryTokens() &&
        [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] != nil;
    NSMutableString *grantLog = [NSMutableString string];
    int64_t (^request)(NSString *, FLBundleGrantMethod) = nil; void (^release)(int64_t) = nil;
    if (FLCanReleaseDirectoryTokens()) {
        request = ^int64_t(NSString *container, FLBundleGrantMethod method) {
            // The reader supplies only the requested bundle's UUID parent, never the bundle root.
            if (!FLIsApplicationBundlePath([container stringByAppendingPathComponent:@"Scope.app"])) return -100;
            if (method == FLBundleGrantTraversal) return FLTraversalTokenForBundleContainer(container, grantLog);
            if (method == FLBundleGrantRootTraversal) return FLTraversalTokenForApplicationBundleRoot(grantLog);
            if (!useGroup) return -101;
            return worse_query(container, group, method == FLBundleGrantAlternate, true);
        };
        release = ^(int64_t token) { FLReleaseDirectoryToken(token); };
    }
    NSError *failure = nil;
    NSDictionary *observed = FLReadBundleEvidence(identifier, readPath, request, release, &failure);
    if (!observed) {
        if (error) {
            if (!grantLog.length) *error = failure;
            else *error = [NSError errorWithDomain:@"ForceLegacyUI.BundleAccess" code:1 userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"%@; %@", failure.localizedDescription ?: @"Bundle read failed", grantLog]}];
        }
        return nil;
    }
    NSMutableDictionary *result = [observed mutableCopy]; result[@"accessDiagnostics"] = grantLog;
    return result;
}
BOOL FLStoreIsDiagnosticOnly(NSString *path) { return FLIsDiagnosticLSStoreName(path.lastPathComponent); }
void FLResetStoreDiscoveryProgress(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"FLStoreInodeCheckpoint"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"FLStoreDescendingInodeCheckpoint"];
}
static NSString *FLNormalize(NSString *path) {
    return FLNormalizeStorePath(path);
}
static id FLWorkspace(void) {
    FLLoadServices();
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    SEL selector = NSSelectorFromString(@"defaultWorkspace");
    if (![cls respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, selector);
}
NSArray<NSDictionary<NSString *, id> *> *FLInstalledApps(NSString **diagnostics) {
    FLLoadServices();
    NSMutableDictionary<NSString *, NSDictionary *> *result = [NSMutableDictionary dictionary];
    NSMutableString *log = [NSMutableString string];
    void (^accept)(id) = ^(id proxy) {
        @try {
            id placeholder = FLValue(proxy, @"placeholder") ?: FLValue(proxy, @"isPlaceholder");
            if ([placeholder isKindOfClass:NSNumber.class] && [placeholder boolValue]) return;
            NSString *identifier = FLString(FLValue(proxy, @"applicationIdentifier"));
            if (!identifier.length) identifier = FLString(FLValue(proxy, @"bundleIdentifier"));
            if (!identifier.length) return;
            id bundleURL = FLValue(proxy, @"bundleURL") ?: FLValue(proxy, @"URL");
            NSString *path = [bundleURL isKindOfClass:NSURL.class] ? FLNormalize([bundleURL path]) : @"";
            NSString *name = FLString(FLValue(proxy, @"localizedName"));
            NSString *sdk = FLString(FLValue(proxy, @"sdkVersion"));
            NSDictionary *previous = result[identifier];
            if (previous && [previous[@"bundlePath"] length] > 0 && path.length == 0) return;
            // Lack of a readable bundle URL must not hide an otherwise visible app.
            result[identifier] = @{@"bundleID":identifier, @"name":name.length ? name : identifier,
                @"bundlePath":path, @"sdk":sdk, @"applicationType":FLString(FLValue(proxy, @"applicationType"))};
        } @catch (NSException *exception) {
            [log appendFormat:@"One application record could not be read: %@.\n", exception.name];
        }
    };
    id workspace = FLWorkspace();
    for (NSString *key in @[@"allInstalledApplications", @"allApplications"]) {
        @try {
            id objects = FLValue(workspace, key);
            if (![objects conformsToProtocol:@protocol(NSFastEnumeration)]) {
                [log appendFormat:@"LSApplicationWorkspace.%@: unavailable.\n", key]; continue;
            }
            NSUInteger count = 0;
            for (id object in objects) { if (++count > 10000) break; accept(object); }
            [log appendFormat:@"LSApplicationWorkspace.%@: %lu raw records, %lu visible apps.\n", key, (unsigned long)count, (unsigned long)result.count];
            if (result.count) break;
        } @catch (NSException *exception) { [log appendFormat:@"%@: %@.\n", key, exception.name]; }
    }
    if (!result.count) {
        Class cls = NSClassFromString(@"LSApplicationRecord");
        SEL selector = NSSelectorFromString(@"enumeratorWithOptions:");
        @try {
            if ([cls respondsToSelector:selector]) {
                id enumerator = ((id (*)(id, SEL, uint64_t))objc_msgSend)(cls, selector, 0);
                NSUInteger count = 0;
                if ([enumerator respondsToSelector:@selector(nextObject)]) {
                    id object;
                    while (count < 10000 && (object = [enumerator nextObject])) { ++count; accept(object); }
                }
                [log appendFormat:@"LSApplicationRecord: %lu raw records, %lu visible apps.\n", (unsigned long)count, (unsigned long)result.count];
            } else { [log appendString:@"LSApplicationRecord enumeration unavailable.\n"]; }
        } @catch (NSException *exception) { [log appendFormat:@"LSApplicationRecord: %@.\n", exception.name]; }
    }
    if (!result.count) {
        SEL selector = NSSelectorFromString(@"enumerateApplicationsOfType:block:");
        if ([workspace respondsToSelector:selector]) {
            @try {
                for (NSUInteger kind = 0; kind < 2; ++kind)
                    ((void (*)(id, SEL, NSUInteger, void (^)(id)))objc_msgSend)(workspace, selector, kind, accept);
                [log appendFormat:@"Workspace callback enumeration: %lu visible apps.\n", (unsigned long)result.count];
            } @catch (NSException *exception) { [log appendFormat:@"Workspace enumeration: %@.\n", exception.name]; }
        }
    }
    if (!result.count) {
        NSArray<NSDictionary *> *metadata = FLMHAAppDataCatalog(log);
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
        NSUInteger lookups = 0;
        for (NSDictionary *record in metadata) {
            NSString *identifier = record[@"bundleID"];
            if (lookups < 512 && [proxyClass respondsToSelector:lookup]) {
                ++lookups;
                @try {
                    id proxy = ((id (*)(id, SEL, NSString *))objc_msgSend)(proxyClass, lookup, identifier);
                    NSString *returnedID = FLString(FLValue(proxy, @"applicationIdentifier"));
                    if (!returnedID.length) returnedID = FLString(FLValue(proxy, @"bundleIdentifier"));
                    if ([returnedID isEqualToString:identifier]) accept(proxy);
                } @catch (NSException *exception) { [log appendFormat:@"Individual LS lookup: %@.\n", exception.name]; }
            }
            NSMutableDictionary *entry = [result[identifier] ?: record mutableCopy];
            entry[@"catalogSource"] = record[@"catalogSource"];
            entry[@"applicationType"] = @"MCM-derived registration (read-only)";
            result[identifier] = entry;
        }
        if (metadata.count) [log appendFormat:@"MCM catalog fallback: %lu registrations; %lu individual LS lookups (limit 512). Missing SDK/path fields stay unavailable.\n",
            (unsigned long)metadata.count, (unsigned long)lookups];
    }
    [log appendString:@"Enumeration may be restricted by iOS. Missing path/SDK fields remain unavailable; they are not guessed.\n"];
    if (diagnostics) *diagnostics = log;
    return result.allValues;
}

NSDictionary<NSString *, id> *FLAppGroupContext(void) {
    NSString *configured = FLString([NSBundle.mainBundle objectForInfoDictionaryKey:@"FLAppGroupIdentifier"]);
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    static void *security; static dispatch_once_t once;
    dispatch_once(&once, ^{ security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL); });
    CFTypeRef (*createTask)(CFAllocatorRef) = security ? dlsym(security, "SecTaskCreateFromSelf") : NULL;
    CFTypeRef (*copyEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *) = security ? dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
    if (createTask && copyEntitlement) {
        CFTypeRef task = createTask(kCFAllocatorDefault);
        if (task) {
            CFErrorRef failure = NULL;
            CFTypeRef value = copyEntitlement(task, CFSTR("com.apple.security.application-groups"), &failure);
            id groups = value ? CFBridgingRelease(value) : nil;
            BOOL succeeded = failure == NULL;
            if (failure) CFRelease(failure);
            CFRelease(task);
            if (succeeded && (!groups || [groups isKindOfClass:NSArray.class])) {
                return @{@"configured":configured, @"bundleID":bundleID, @"groups":groups ?: @[], @"source":@"Running signature (SecTask)"};
            }
        }
    }
    // The profile is a source of candidate names only. containerURL remains the permission check.
    NSURL *profileURL = [NSBundle.mainBundle URLForResource:@"embedded" withExtension:@"mobileprovision"];
    id sizeValue = nil; [profileURL getResourceValue:&sizeValue forKey:NSURLFileSizeKey error:nil];
    NSNumber *size = [sizeValue isKindOfClass:NSNumber.class] ? sizeValue : nil;
    if (size && size.unsignedLongLongValue <= 8 * 1024 * 1024) {
        NSData *data = [NSData dataWithContentsOfURL:profileURL];
        NSRange start = [data rangeOfData:[@"<?xml" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, data.length)];
        if (data && start.location != NSNotFound) {
            NSRange end = [data rangeOfData:[@"</plist>" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(start.location, data.length - start.location)];
            if (end.location != NSNotFound) {
                NSData *xml = [data subdataWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)];
                id plist = [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:nil];
                if ([plist isKindOfClass:NSDictionary.class]) {
                    id entitlements = plist[@"Entitlements"];
                    id groups = [entitlements isKindOfClass:NSDictionary.class] ? entitlements[@"com.apple.security.application-groups"] : nil;
                    return @{@"configured":configured, @"bundleID":bundleID, @"groups":[groups isKindOfClass:NSArray.class] ? groups : @[], @"source":@"Embedded profile (runtime access still required)"};
                }
            }
        }
    }
    return @{@"configured":configured, @"bundleID":bundleID, @"groups":@[], @"source":@"Entitlement metadata unavailable; checking configured group directly"};
}
static NSString *FLSysctl(const char *key) {
    char buffer[256] = {0}; size_t size = sizeof(buffer);
    if (sysctlbyname(key, buffer, &size, NULL, 0) != 0) return @"unknown";
    return [NSString stringWithUTF8String:buffer] ?: @"unknown";
}
NSDictionary<NSString *, NSString *> *FLDeviceInfo(void) {
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *build = FLSysctl("kern.osversion");
#if TARGET_OS_SIMULATOR
    build = [@"simulator-host-kernel:" stringByAppendingString:build];
    NSString *environment = @"simulator";
#else
    NSString *environment = @"physical-device";
#endif
    return @{@"osVersion":[NSString stringWithFormat:@"%ld.%ld.%ld", (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion],
             @"osBuild":build, @"environment":environment, @"model":FLSysctl("hw.machine"),
             @"architecture":FLArchitectureForMachHeader(_dyld_get_image_header(0))};
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

static NSArray<NSString *> *FLMappedStores(NSMutableString *log) {
    // A direct record lookup can map the client DB even when bulk enumeration is denied.
    FLLoadServices();
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if ([cls respondsToSelector:selector]) {
        for (NSString *identifier in @[NSBundle.mainBundle.bundleIdentifier ?: @"", @"com.apple.mobilesafari"]) {
            if (!identifier.length) continue;
            @try {
                id proxy = ((id (*)(id, SEL, NSString *))objc_msgSend)(cls, selector, identifier);
                [log appendFormat:@"Client database lookup %@: %@.\n", identifier, proxy ? @"returned an object (not installation proof)" : @"no object"];
            } @catch (NSException *exception) { [log appendFormat:@"Client database lookup: %@.\n", exception.name]; }
        }
    } else { [log appendString:@"Client database lookup API unavailable.\n"]; }
    int (*filename)(int, uint64_t, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_regionfilename");
    if (!filename) { [log appendString:@"proc_regionfilename unavailable.\n"]; return @[]; }
    NSMutableOrderedSet *paths = [NSMutableOrderedSet orderedSet];
    vm_address_t address = 0;
    unsigned regions = 0;
    for (unsigned i = 0; i < 16384; ++i) {
        vm_size_t size = 0; vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t object = MACH_PORT_NULL;
        kern_return_t status = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (status != KERN_SUCCESS || size == 0 || UINTPTR_MAX - address < size) break;
        ++regions;
        char buffer[PATH_MAX] = {0};
        if (filename(getpid(), address, buffer, sizeof(buffer)) > 0) {
            NSString *path = FLNormalize([NSString stringWithUTF8String:buffer] ?: @"");
            if ((FLIsLaunchServicesStoreName(path.lastPathComponent) || FLIsDiagnosticLSStoreName(path.lastPathComponent)) &&
                FLIsAllowedStoreDirectory(path.stringByDeletingLastPathComponent)) [paths addObject:path];
        }
        address += size;
    }
    [log appendFormat:@"Mapped-region inspection: %u regions examined.\n", regions];
    return paths.array;
}
static NSString *FLContainerDirectory(uint64_t kind, NSMutableString *log) {
    void *lib = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!lib) { [log appendFormat:@"lsd container class %llu: library unavailable.\n", kind]; return nil; }
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
        } else { [log appendFormat:@"lsd container class %llu: query allocation failed.\n", kind]; }
    } else { [log appendFormat:@"lsd container class %llu: metadata API unavailable.\n", kind]; }
    dlclose(lib);
    [log appendFormat:@"lsd container class %llu: %@.\n", kind, path ?: @"no metadata path returned"];
    if (path && !FLIsAllowedStoreDirectory(path)) [log appendString:@"Metadata path is outside the cache discovery allowlist.\n"];
    return FLIsAllowedStoreDirectory(path) ? path : nil;
}
static NSArray<NSString *> *FLInodeDiscovery(NSTimeInterval deadline, NSMutableString *log) {
    struct statfs volume;
    if (statfs(NSHomeDirectory().fileSystemRepresentation, &volume) != 0) {
        [log appendFormat:@"Inode discovery statfs failed: errno %d.\n", errno]; return @[];
    }
    NSString *context = [NSString stringWithFormat:@"v2:%d:%d:%@:%@:%@", volume.f_fsid.val[0], volume.f_fsid.val[1],
        FLSysctl("kern.osversion"), FLSysctl("hw.machine"), FLSysctl("kern.bootsessionuuid")];
    uint64_t probeInode = 0;
    NSString *probe = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"FLInode-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    int descriptor = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (descriptor >= 0) {
        struct stat attributes; struct statfs probeVolume;
        if (fstat(descriptor, &attributes) == 0 && fstatfs(descriptor, &probeVolume) == 0 &&
            probeVolume.f_fsid.val[0] == volume.f_fsid.val[0] && probeVolume.f_fsid.val[1] == volume.f_fsid.val[1]) probeInode = attributes.st_ino;
        close(descriptor);
        if (unlink(probe.fileSystemRepresentation) != 0) [log appendFormat:@"App-owned inode probe cleanup failed: errno %d.\n", errno];
    } else {
        [log appendFormat:@"App-owned inode probe creation failed: errno %d; using fallback upper bound.\n", errno];
    }
    NSDictionary *next = nil; __block uint64_t resolvedPaths = 0;
    NSArray *directories = FLScanStoreInodes(probeInode,
        [NSUserDefaults.standardUserDefaults dictionaryForKey:@"FLStoreDescendingInodeCheckpoint"], context, deadline,
        ^NSString *(uint64_t inode) {
            char buffer[PATH_MAX] = {0};
            fsid_t identifier = volume.f_fsid;
            if (fsgetpath(buffer, sizeof(buffer), &identifier, inode) <= 0) return nil;
            ++resolvedPaths;
            if (!strstr(buffer, "com.apple.LaunchServices-") && !strstr(buffer, "/Containers/Data/InternalDaemon/") &&
                !strstr(buffer, "/containers/Data/System/") && !strstr(buffer, "/Containers/Data/System/")) return nil;
            return [NSString stringWithUTF8String:buffer];
        }, ^NSTimeInterval { return NSProcessInfo.processInfo.systemUptime; }, &next, log);
    if (next) [NSUserDefaults.standardUserDefaults setObject:next forKey:@"FLStoreDescendingInodeCheckpoint"];
    [log appendFormat:@"fsgetpath resolved %llu paths; string decoding limited to LS names/system-container candidates.\n", (unsigned long long)resolvedPaths];
    return directories;
}
static int64_t FLGrantDirectory(NSString *directory, NSString *group, NSMutableString *log) {
    BOOL (^readable)(int *) = ^BOOL(int *failure) {
        int descriptor = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (descriptor < 0) { *failure = errno; return NO; }
        close(descriptor); return YES;
    };
    if (group.length && FLCanReleaseDirectoryTokens()) {
        int64_t token = FLVerifiedDirectoryGrant(directory, ^int64_t(BOOL alternate) {
            // Skip the pre-grant lstat: sandbox denial is not reliable proof of absence.
            // worse_query never creates the external target.
            return worse_query(directory, group, alternate, true);
        }, ^(int64_t handle) { FLReleaseDirectoryToken(handle); }, readable, log);
        if (token >= 0) return token;
    }
    int64_t token = FLTraversalTokenForCacheDirectory(directory, log);
    if (token >= 0) {
        int failure = 0;
        if (readable(&failure)) return token;
        FLReleaseDirectoryToken(token);
        [log appendFormat:@"Traversal handle released; read-only directory probe failed, errno %d.\n", failure];
    }
    return -1;
}
@interface FLNativeStoreDiscoveryAccess : NSObject <FLStoreDiscoveryAccess>
@property (nonatomic, strong) NSMutableArray<FLLSDContainerLease *> *leases;
@end
@implementation FLNativeStoreDiscoveryAccess
- (instancetype)init { if ((self = [super init])) _leases = [NSMutableArray array]; return self; }
- (NSArray<NSString *> *)mappedStorePathsWithLog:(NSMutableString *)log { return FLMappedStores(log); }
- (NSString *)cacheDirectoryForContainerClass:(uint64_t)kind log:(NSMutableString *)log {
    if ([FLAccessMode() isEqualToString:@"house-arrest"]) {
        FLLSDContainerLease *lease = [FLLSDContainerLease openForClass:kind log:log];
        if (lease) { [self.leases addObject:lease]; return lease.cacheDirectory; }
    }
    return FLContainerDirectory(kind, log);
}
- (NSArray<NSString *> *)inodeCacheDirectoriesWithDeadline:(NSTimeInterval)deadline log:(NSMutableString *)log { return FLInodeDiscovery(deadline, log); }
- (NSArray<NSString *> *)storePathsInDirectory:(NSString *)directory group:(NSString *)group log:(NSMutableString *)log {
    int64_t token = -1;
    NSMutableArray *paths = [NSMutableArray array];
    DIR *stream = NULL;
    @try {
        int fd = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) {
            token = FLGrantDirectory(directory, group, log);
            if (token < 0) return @[];
            fd = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        } else { [log appendFormat:@"Cache directory already readable under current access: %@.\n", directory]; }
        if (fd < 0) { [log appendFormat:@"Cache directory open failed: errno %d.\n", errno]; return @[]; }
        stream = fdopendir(fd);
        if (!stream) { int failure = errno; close(fd); [log appendFormat:@"Cache listing failed: errno %d.\n", failure]; return @[]; }
        NSUInteger entries = 0; struct dirent *entry;
        while (true) {
            errno = 0; entry = readdir(stream);
            if (!entry) {
                if (errno) { [log appendFormat:@"Cache listing interrupted: errno %d.\n", errno]; return @[]; }
                break;
            }
            if (++entries > 4096) { [log appendString:@"Cache listing exceeded 4096 entries; refusing incomplete candidate selection.\n"]; return @[]; }
            NSString *name = [NSString stringWithUTF8String:entry->d_name];
            if (!name || (!FLIsLaunchServicesStoreName(name) && !FLIsDiagnosticLSStoreName(name))) continue;
            if (FLIsDiagnosticLSStoreName(name)) [log appendFormat:@"Prefixed LS cache observed: %@; catalog role unverified, diagnostic only.\n", name];
            struct stat st;
            if (fstatat(dirfd(stream), entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
                [log appendFormat:@"Matching cache metadata unavailable: errno %d.\n", errno]; continue;
            }
            if (!S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size < 100 || st.st_size > 64 * 1024 * 1024) {
                [log appendString:@"Matching cache rejected: file type, link count or size.\n"]; continue;
            }
            [paths addObject:[directory stringByAppendingPathComponent:name]];
        }
        [log appendFormat:@"Cache listing: %lu entries, %lu matching regular stores.\n", (unsigned long)entries, (unsigned long)paths.count];
        return paths;
    } @finally { if (stream) closedir(stream); FLReleaseDirectoryToken(token); }
}
- (NSArray<NSString *> *)cacheDirectoriesInRoot:(NSString *)root group:(NSString *)group
                                      deadline:(NSTimeInterval)deadline log:(NSMutableString *)log {
    if (![FLStoreContainerRoots() containsObject:root]) return @[];
    int64_t token = -1;
    NSMutableArray *directories = [NSMutableArray array]; DIR *stream = NULL;
    @try {
        int fd = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) {
            token = FLGrantDirectory(root, group, log);
            if (token < 0) return @[];
            fd = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }
        if (fd < 0) { [log appendFormat:@"Container root open failed: errno %d.\n", errno]; return @[]; }
        stream = fdopendir(fd);
        if (!stream) { int failure = errno; close(fd); [log appendFormat:@"Container root listing failed: errno %d.\n", failure]; return @[]; }
        NSUInteger entries = 0; struct dirent *entry;
        while (entries < 2048 && directories.count < 256 && NSProcessInfo.processInfo.systemUptime < deadline) {
            errno = 0; entry = readdir(stream);
            if (!entry) { if (errno) [log appendFormat:@"Container root listing interrupted: errno %d.\n", errno]; break; }
            ++entries;
            NSString *name = [NSString stringWithUTF8String:entry->d_name];
            if (!name || (![[NSUUID alloc] initWithUUIDString:name] && ![name isEqualToString:@"com.apple.lsd"])) continue;
            NSString *directory = [[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Library/Caches"];
            if (FLIsAllowedStoreDirectory(directory)) [directories addObject:directory];
        }
        [log appendFormat:@"Container root %@: %lu names inspected; %lu cache-directory candidates (bounded; not container identity proof).\n",
            root, (unsigned long)entries, (unsigned long)directories.count];
        return directories;
    } @finally { if (stream) closedir(stream); FLReleaseDirectoryToken(token); }
}
@end
@interface FLStoreSession ()
@property (nonatomic, readwrite, copy) NSString *path;
@property (nonatomic, readwrite, copy) NSString *diagnostics;
@property (nonatomic) int64_t token;
@property (nonatomic, strong) NSObject *accessOwner;
@end
@implementation FLStoreSession
- (instancetype)init { if ((self = [super init])) _token = -1; return self; }
- (void)endAccess { if (_token >= 0) { FLReleaseDirectoryToken(_token); _token = -1; } self.accessOwner = nil; }
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
    BOOL houseArrest = [FLAccessMode() isEqualToString:@"house-arrest"];
    if (houseArrest && !FLHouseArrestIdentityAllowed(NSBundle.mainBundle.bundleIdentifier ?: @"", FLAccessMode())) {
        if (error) *error = FLError(@"The MHA build requires enterprise signing that preserves com.apple.mobile.MobileHouseArrest. Its bundle identifier was changed; no MHA query was attempted.");
        return nil;
    }
    if (!houseArrest && (group.length == 0 || ![NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group])) {
        if (error) *error = FLError(@"A provisioned, dedicated App Group is required. Set FLAppGroupIdentifier and sign with matching application-groups entitlement.");
        return nil;
    }
    NSMutableString *log = [NSMutableString string];
    [log appendString:FLContainerRuntimeDiagnostics()];
    [log appendFormat:@"Access backend: %@.\n", houseArrest ? @"MHA lsd lease + scoped traversal fallback" : @"App Group / worse_query + scoped traversal fallback"];
    FLNativeStoreDiscoveryAccess *access = [FLNativeStoreDiscoveryAccess new];
    NSString *path = [FLStoreDiscovery findStoreUsing:access group:group
        cachedDirectory:cachedDirectory extended:extendedSearch log:log error:error];
    if (!path) return nil;
    int64_t token = -1;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd >= 0) close(fd);
    else token = FLGrantDirectory(path.stringByDeletingLastPathComponent, group, log);
    if (fd < 0 && token < 0) {
        if (error) *error = FLError([NSString stringWithFormat:@"Could not reacquire the selected directory extension.\n%@", log]);
        return nil;
    }
    FLStoreSession *session = [FLStoreSession new]; session.path = path; session.token = token; session.diagnostics = log; session.accessOwner = access;
    return session;
#endif
}
