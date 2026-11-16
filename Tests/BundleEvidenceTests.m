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
            check(!FLReadBundleEvidence(@"org.example.sdk", path, ^int64_t(BOOL alt) { (void)alt; ++requests; return 1; }, ^(int64_t token) { (void)token; }, NULL), @"Unrelated bundle path accepted");
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
    return passed;
}
