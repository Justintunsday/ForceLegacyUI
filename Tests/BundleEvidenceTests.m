// SPDX-License-Identifier: GPL-3.0-or-later
#import "FLBundleEvidence.h"
#include <fcntl.h>
#include <unistd.h>

static void check(BOOL value, NSString *message) { if (!value) [NSException raise:@"BundleEvidenceRegression" format:@"%@", message]; }
static void little(NSMutableData *data, NSUInteger offset, uint32_t value) {
    uint8_t bytes[] = {value&255, (value>>8)&255, (value>>16)&255, value>>24};
    [data replaceBytesInRange:NSMakeRange(offset, 4) withBytes:bytes];
}
static void big(NSMutableData *data, NSUInteger offset, uint32_t value) {
    uint8_t bytes[] = {value>>24, (value>>16)&255, (value>>8)&255, value&255};
    [data replaceBytesInRange:NSMakeRange(offset, 4) withBytes:bytes];
}
static NSMutableData *executable(uint32_t sdk) {
    NSMutableData *data = [NSMutableData dataWithLength:56];
    little(data, 0, 0xfeedfacf); little(data, 4, 0x0100000c); little(data, 12, 2);
    little(data, 16, 1); little(data, 20, 24); little(data, 32, 0x32); little(data, 36, 24);
    little(data, 40, 2); little(data, 44, 0x120000); little(data, 48, sdk);
    return data;
}
static NSDictionary *bundleFixture(BOOL withInfo) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *app = [root stringByAppendingPathComponent:@"Example.app"];
    NSFileManager *files = NSFileManager.defaultManager;
    check([files createDirectoryAtPath:app withIntermediateDirectories:YES attributes:nil error:NULL], @"Fixture directory failed");
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"org.example.sdk", @"CFBundleExecutable":@"Runner"}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    check([executable(0x1a0200) writeToFile:[app stringByAppendingPathComponent:@"Runner"] atomically:YES], @"Fixture executable failed");
    if (withInfo) check([plist writeToFile:[app stringByAppendingPathComponent:@"Info.plist"] atomically:YES], @"Fixture Info failed");
    return @{@"root":root, @"app":app, @"info":plist};
}
NSArray<NSString *> *FLRunBundleEvidenceTests(void) {
    NSMutableArray *passed = [NSMutableArray array];
    void (^test)(NSString *, void (^)(void)) = ^(NSString *name, void (^body)(void)) { body(); [passed addObject:name]; };
    test(@"Thin arm64 executable SDK comes from device load commands", ^{
        NSDictionary *result = FLTestMachOObservation(executable(0x1a0200), NULL);
        check([result[@"sdk"] isEqual:@"26.2.0"] && [result[@"loadCommands"] length] > 0, @"SDK/load-command evidence was not captured");
    });
    test(@"Non-device and malformed executable commands are rejected", ^{
        NSMutableData *data = executable(0x1a0200); little(data, 40, 7);
        check(!FLTestMachOObservation(data, NULL), @"Simulator SDK was treated as device evidence");
        data = executable(0x1a0200); little(data, 36, 1024);
        check(!FLTestMachOObservation(data, NULL), @"Out-of-bounds command was accepted");
        data = executable(0x1a0200); little(data, 12, 6);
        check(!FLTestMachOObservation(data, NULL), @"A dylib was treated as the app executable");
        check(!FLTestMachOObservation([data subdataWithRange:NSMakeRange(0, 31)], NULL), @"Truncated header was accepted");
    });
    test(@"Universal arm64 slices must agree on the build SDK", ^{
        NSMutableData *data = [NSMutableData dataWithLength:184]; big(data, 0, 0xcafebabe); big(data, 4, 2);
        big(data, 8, 0x0100000c); big(data, 16, 64); big(data, 20, 56);
        big(data, 28, 0x0100000c); big(data, 32, 2); big(data, 36, 128); big(data, 40, 56);
        [data replaceBytesInRange:NSMakeRange(64, 56) withBytes:executable(0x1a0200).bytes];
        [data replaceBytesInRange:NSMakeRange(128, 56) withBytes:executable(0x1a0200).bytes];
        check([FLTestMachOObservation(data, NULL)[@"sdk"] isEqual:@"26.2.0"], @"Valid universal SDK could not be read");
        little(data, 128+48, 0x1a0500);
        check(!FLTestMachOObservation(data, NULL), @"Conflicting slices authorized an SDK observation");
        big(data, 16, UINT32_MAX);
        check(!FLTestMachOObservation(data, NULL), @"An out-of-bounds universal slice was read");
    });
    test(@"Bundle scope rejects application data and path traversal before token requests", ^{
        NSString *bundle = @"/private/var/containers/Bundle/Application/04BA7A11-12F4-4567-89AB-0123456789AB/Example.app";
        check(FLIsApplicationBundlePath(bundle), @"Canonical application bundle refused");
        __block unsigned requests = 0;
        for (NSString *path in @[[bundle stringByAppendingString:@"/../Other.app"],
            @"/private/var/mobile/Containers/Data/Application/04BA7A11-12F4-4567-89AB-0123456789AB/Example.app"]) {
            check(!FLReadBundleEvidence(@"org.example.sdk", path, ^int64_t(NSString *container, FLBundleGrantMethod method) { (void)container; (void)method; ++requests; return 1; }, ^(int64_t token) { (void)token; }, NULL), @"Unrelated bundle path accepted");
        }
        check(!requests, @"Rejected metadata path reached a private grant API");
    });
    test(@"Bundle metadata reads the expected Info identity and regular executable", ^{
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        check([files createDirectoryAtPath:root withIntermediateDirectories:NO attributes:nil error:NULL], @"Test directory creation failed");
        int directory = -1;
        @try {
            NSData *plist = [NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"org.example.sdk", @"CFBundleExecutable":@"Runner"}
                format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
            check([plist writeToFile:[root stringByAppendingPathComponent:@"Info.plist"] atomically:YES] &&
                  [executable(0x1a0200) writeToFile:[root stringByAppendingPathComponent:@"Runner"] atomically:YES], @"Test metadata could not be written");
            directory = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            NSDictionary *result = FLTestBundleAtFD(directory, @"org.example.sdk", NULL);
            check([result[@"sdk"] isEqual:@"26.2.0"] && [result[@"infoData"] isEqual:plist], @"Read-only bundle metadata was not captured");
            check(!FLTestBundleAtFD(directory, @"org.other.app", NULL), @"Mismatched bundle identity accepted");
            NSString *runner = [root stringByAppendingPathComponent:@"Runner"];
            check([files moveItemAtPath:runner toPath:[root stringByAppendingPathComponent:@"Original"] error:NULL] &&
                  symlink("Original", runner.fileSystemRepresentation) == 0, @"Symlink fixture setup failed");
            check(!FLTestBundleAtFD(directory, @"org.example.sdk", NULL), @"Executable symlink was followed");
        } @finally { if (directory >= 0) close(directory); [files removeItemAtPath:root error:NULL]; }
    });
    test(@"Folded bundle names resolve uniquely and bounded listings reject ambiguity", ^{
        check([FLTestMatchBundleName(@[@"Example.app", @"metadata.plist"], @"example.app", NULL) isEqual:@"Example.app"], @"Actual bundle spelling was not retained");
        check(!FLTestMatchBundleName(@[@"Example.app", @"example.app"], @"example.app", NULL), @"Ambiguous spelling selected an arbitrary app");
        check(!FLTestMatchBundleName(@[@"Other.app", @"../Example.app"], @"example.app", NULL), @"Unrelated or traversing name was selected");
        NSMutableArray *names = [NSMutableArray array]; for (unsigned i = 0; i < 65; ++i) [names addObject:@"metadata"];
        check(!FLTestMatchBundleName(names, @"example.app", NULL), @"Oversized directory listing was accepted");
    });
    test(@"Resolved bundle still requires the expected Info identifier and executable SDK", ^{
        NSDictionary *fixture = bundleFixture(YES);
        @try {
            NSDictionary *result = FLTestResolveBundle(@"org.example.sdk", fixture[@"root"], @"example.app", nil, nil, NULL);
            check([result[@"sdk"] isEqual:@"26.2.0"] && [[result[@"bundlePath"] lastPathComponent] caseInsensitiveCompare:@"Example.app"] == NSOrderedSame, @"Folded registration could not be independently read");
            check(!FLTestResolveBundle(@"org.other.app", fixture[@"root"], @"example.app", nil, nil, NULL), @"Case resolution bypassed bundle identity");
        } @finally { [NSFileManager.defaultManager removeItemAtPath:fixture[@"root"] error:NULL]; }
    });
    test(@"Readable bundle directory retries a paired grant when its Info file is unreadable", ^{
        NSDictionary *fixture = bundleFixture(NO); __block unsigned requests = 0; NSMutableArray *released = [NSMutableArray array];
        @try {
            NSDictionary *result = FLTestResolveBundle(@"org.example.sdk", fixture[@"root"], @"Example.app", ^int64_t(NSString *container, FLBundleGrantMethod method) {
                ++requests; check(method == FLBundleGrantStandard && [container.lastPathComponent isEqual:[fixture[@"root"] lastPathComponent]], @"Grant escaped requested container");
                check([fixture[@"info"] writeToFile:[fixture[@"app"] stringByAppendingPathComponent:@"Info.plist"] atomically:YES], @"Injected access response failed"); return 0;
            }, ^(int64_t token) { [released addObject:@(token)]; }, NULL);
            check([result[@"sdk"] isEqual:@"26.2.0"] && requests == 1 && [released isEqual:@[@0]], @"Subfile access skipped grant retry or leaked handle zero");
        } @finally { [NSFileManager.defaultManager removeItemAtPath:fixture[@"root"] error:NULL]; }
    });
    test(@"A positive but ineffective bundle grant is released before alternate flags", ^{
        NSDictionary *fixture = bundleFixture(NO); NSMutableArray *released = [NSMutableArray array];
        @try {
            NSDictionary *result = FLTestResolveBundle(@"org.example.sdk", fixture[@"root"], @"Example.app", ^int64_t(NSString *container, FLBundleGrantMethod method) {
                (void)container;
                check(method != FLBundleGrantTraversal, @"Traversal called after successful alternate read");
                if (method == FLBundleGrantAlternate) {
                    check([released isEqual:@[@40]], @"Ineffective grant was retained");
                    check([fixture[@"info"] writeToFile:[fixture[@"app"] stringByAppendingPathComponent:@"Info.plist"] atomically:YES], @"Injected alternate response failed");
                }
                return method == FLBundleGrantAlternate ? 41 : 40;
            }, ^(int64_t token) { [released addObject:@(token)]; }, NULL);
            check([result[@"sdk"] isEqual:@"26.2.0"] && [released isEqual:@[@40, @41]], @"Alternate read or token pairing failed");
        } @finally { [NSFileManager.defaultManager removeItemAtPath:fixture[@"root"] error:NULL]; }
    });
    test(@"Denied and unpaired bundle grants retain the failed path and access stage", ^{
        NSDictionary *fixture = bundleFixture(NO); __block unsigned requests = 0;
        @try {
            int64_t (^request)(NSString *, FLBundleGrantMethod) = ^int64_t(NSString *container, FLBundleGrantMethod method) { (void)container; (void)method; ++requests; return -6; };
            NSError *error = nil;
            check(!FLTestResolveBundle(@"org.example.sdk", fixture[@"root"], @"Example.app", request, ^(int64_t token) { (void)token; check(NO, @"Denied grant was released as a token"); }, &error), @"Denied grants produced evidence");
            check(requests == 4 && [error.localizedDescription containsString:@"Info.plist open failed"] && [error.localizedDescription containsString:@"Bundle-root traversal UUID-container grant: -6"], @"Per-stage diagnostics or traversal attempt missing");
            requests = 0;
            check(!FLTestResolveBundle(@"org.example.sdk", fixture[@"root"], @"Example.app", request, nil, NULL) && !requests, @"Consumed an unpaired token");
        } @finally { [NSFileManager.defaultManager removeItemAtPath:fixture[@"root"] error:NULL]; }
    });
    test(@"Bundle identity conflicts and symlinks never trigger additional grants", ^{
        NSDictionary *fixture = bundleFixture(YES); __block unsigned requests = 0;
        @try {
            int64_t (^request)(NSString *, FLBundleGrantMethod) = ^int64_t(NSString *container, FLBundleGrantMethod method) { (void)container; (void)method; ++requests; return 1; };
            void (^release)(int64_t) = ^(int64_t token) { (void)token; };
            check(!FLTestResolveBundle(@"org.other.app", fixture[@"root"], @"Example.app", request, release, NULL) && !requests, @"Identity mismatch retried grants");
            NSString *alias = [fixture[@"root"] stringByAppendingPathComponent:@"Alias.app"];
            check(symlink("Example.app", alias.fileSystemRepresentation) == 0, @"Symlink fixture failed");
            check(!FLTestResolveBundle(@"org.example.sdk", fixture[@"root"], @"Alias.app", request, release, NULL) && !requests, @"Symlink triggered a grant or was followed");
        } @finally { [NSFileManager.defaultManager removeItemAtPath:fixture[@"root"] error:NULL]; }
    });
    test(@"Scoped traversal is attempted after both worse_query methods are denied", ^{
        NSDictionary *fixture = bundleFixture(NO); NSMutableArray *methods = [NSMutableArray array], *released = [NSMutableArray array];
        @try {
            NSDictionary *result = FLTestResolveBundle(@"org.example.sdk", fixture[@"root"], @"Example.app", ^int64_t(NSString *container, FLBundleGrantMethod method) {
                (void)container; [methods addObject:@(method)];
                if (method != FLBundleGrantTraversal) return -6;
                check([fixture[@"info"] writeToFile:[fixture[@"app"] stringByAppendingPathComponent:@"Info.plist"] atomically:YES], @"Injected traversal access failed");
                return 73;
            }, ^(int64_t token) { [released addObject:@(token)]; }, NULL);
            check([result[@"sdk"] isEqual:@"26.2.0"] && [methods isEqual:@[@0, @1, @2]] && [released isEqual:@[@73]], @"Traversal read or paired release failed");
        } @finally { [NSFileManager.defaultManager removeItemAtPath:fixture[@"root"] error:NULL]; }
    });
    test(@"Unavailable worse_query symbols do not disable an independent traversal backend", ^{
        NSDictionary *fixture = bundleFixture(NO); __block unsigned requests = 0, releases = 0;
        @try {
            NSDictionary *result = FLTestResolveBundle(@"org.example.sdk", fixture[@"root"], @"Example.app", ^int64_t(NSString *container, FLBundleGrantMethod method) {
                (void)container; ++requests;
                if (method != FLBundleGrantTraversal) return -2;
                check([fixture[@"info"] writeToFile:[fixture[@"app"] stringByAppendingPathComponent:@"Info.plist"] atomically:YES], @"Injected independent access failed");
                return 0;
            }, ^(int64_t token) { check(token == 0, @"Wrong traversal token released"); ++releases; }, NULL);
            check([result[@"sdk"] isEqual:@"26.2.0"] && requests == 3 && releases == 1, @"Unavailable primary backend blocked traversal");
        } @finally { [NSFileManager.defaultManager removeItemAtPath:fixture[@"root"] error:NULL]; }
    });
    test(@"Fixed-root grant fallback keeps metadata reads bound to the requested UUID", ^{
        NSDictionary *fixture = bundleFixture(NO); NSMutableArray *methods = [NSMutableArray array], *released = [NSMutableArray array];
        @try {
            NSDictionary *result = FLTestResolveBundle(@"org.example.sdk", fixture[@"root"], @"Example.app", ^int64_t(NSString *container, FLBundleGrantMethod method) {
                check([container.lastPathComponent isEqual:[fixture[@"root"] lastPathComponent]], @"Root capability changed the actual read target");
                [methods addObject:@(method)];
                if (method != FLBundleGrantRootTraversal) return -6;
                check([fixture[@"info"] writeToFile:[fixture[@"app"] stringByAppendingPathComponent:@"Info.plist"] atomically:YES], @"Injected root-grant response failed");
                return 73;
            }, ^(int64_t token) { [released addObject:@(token)]; }, NULL);
            check([result[@"sdk"] isEqual:@"26.2.0"] && [methods isEqual:@[@0, @1, @2, @3]] && [released isEqual:@[@73]], @"Root fallback read or release failed");
        } @finally { [NSFileManager.defaultManager removeItemAtPath:fixture[@"root"] error:NULL]; }
    });
    return passed;
}
