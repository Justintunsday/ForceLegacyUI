// SPDX-License-Identifier: GPL-3.0-or-later
#import "FLStoreDiscovery.h"
#include <errno.h>

static void check(BOOL value, NSString *message) { if (!value) [NSException raise:@"StoreScanRegression" format:@"%@", message]; }
NSArray<NSString *> *FLRunStoreScanTests(void) {
    NSMutableArray *passed = [NSMutableArray array];
    void (^test)(NSString *, void (^)(void)) = ^(NSString *name, void (^body)(void)) { body(); [passed addObject:name]; };
    NSString *cache = @"/private/var/mobile/Containers/Data/InternalDaemon/04BA7A11-12F4-4567-89AB-0123456789AB/Library/Caches";
    NSString *primary = [cache stringByAppendingPathComponent:@"com.apple.LaunchServices-1-v2.csstore"];
    test(@"An unreadable positive token is released before trying alternate flags", ^{
        __block unsigned requests = 0, probes = 0; NSMutableArray *released = [NSMutableArray array];
        int64_t token = FLVerifiedDirectoryGrant(cache, ^int64_t(BOOL alternate) {
            check(alternate == (requests == 1), @"Query flags were not tried in order"); return 10 + requests++;
        }, ^(int64_t handle) { [released addObject:@(handle)]; }, ^BOOL(int *failure) {
            *failure = EPERM; return ++probes == 2;
        }, [NSMutableString string]);
        check(token == 11 && requests == 2 && [released isEqual:@[@10]], @"Failed token leaked or alternate readable token was rejected");
    });
    test(@"All unreadable grants are released and neither errno is treated as success", ^{
        __block unsigned released = 0, probes = 0;
        int64_t token = FLVerifiedDirectoryGrant(cache, ^int64_t(BOOL alternate) { return alternate ? 12 : 11; },
            ^(int64_t handle) { (void)handle; ++released; }, ^BOOL(int *failure) { *failure = ++probes == 1 ? EPERM : EACCES; return NO; }, [NSMutableString string]);
        check(token < 0 && released == 2, @"A consumed token or EACCES was mistaken for usable read access");
    });
    test(@"Unavailable grant APIs and unrelated targets never issue redundant queries", ^{
        __block unsigned requests = 0;
        int64_t (^request)(BOOL) = ^int64_t(BOOL alternate) { (void)alternate; ++requests; return -2; };
        void (^release)(int64_t) = ^(int64_t handle) { (void)handle; check(NO, @"Invalid token released"); };
        BOOL (^probe)(int *) = ^BOOL(int *failure) { (void)failure; check(NO, @"Missing token was probed"); return NO; };
        check(FLVerifiedDirectoryGrant(cache, request, release, probe, [NSMutableString string]) == -2 && requests == 1, @"Missing API was retried");
        check(FLVerifiedDirectoryGrant(@"/private/var/mobile/Containers/Data/Application", request, release, probe, [NSMutableString string]) == -100 && requests == 1, @"Unrelated target reached token APIs");
    });
    test(@"The inode anchor can exceed forty million without unsigned overflow", ^{
        check(FLInodeScanUpperBound(50000000) == 50262144, @"Recent inode anchor was truncated to the old ceiling");
        check(FLInodeScanUpperBound(0) == 40000000 && FLInodeScanUpperBound(UINT64_MAX) == 40000000, @"Unavailable/overflowing anchor did not use a bounded fallback");
    });
    test(@"Recent inodes are searched descending and real LS filenames outrank generic paths", ^{
        uint64_t upper = FLInodeScanUpperBound(50000000); __block uint64_t visits = 0, first = 0;
        NSArray *found = FLScanStoreInodes(50000000, nil, @"volume:build:boot", 1.0, ^NSString *(uint64_t inode) {
            if (!visits++) first = inode;
            if (inode == upper - 1000) return primary;
            if (visits <= 64) return [NSString stringWithFormat:@"/private/var/containers/Data/System/00000000-0000-0000-0000-%012llu/Library/a", (unsigned long long)visits];
            return nil;
        }, ^NSTimeInterval { return (double)visits / 1000000; }, NULL, [NSMutableString string]);
        check(first == upper && [found.firstObject isEqual:cache] && found.count <= 64, @"Low-to-high scan or generic-directory limit hid the store");
        check(visits < 300000, @"Primary sibling window was not bounded");
    });
    test(@"A prefixed LS observation never shortens the search for a primary source", ^{
        uint64_t upper = FLInodeScanUpperBound(50000000); __block uint64_t visits = 0;
        NSString *diagnostic = @"/private/var/db/lsd/SystemDataOnly-com.apple.LaunchServices-2-v2.csstore";
        NSArray *found = FLScanStoreInodes(50000000, nil, @"volume", 1.0, ^NSString *(uint64_t inode) {
            ++visits;
            if (inode == upper - 10) return diagnostic;
            if (inode == upper - 300000) return primary;
            return nil;
        }, ^NSTimeInterval { return (double)visits / 1000000; }, NULL, [NSMutableString string]);
        check([found containsObject:cache] && [found containsObject:@"/private/var/db/lsd"], @"Diagnostic cache stopped the primary search");
    });
    test(@"A bounded older sweep resumes after revisiting the recent window", ^{
        uint64_t upper = FLInodeScanUpperBound(50000000), older = upper - 2000000;
        NSDictionary *checkpoint = @{@"schema":@2, @"context":@"volume", @"upper":@(upper), @"next":@(older)};
        __block uint64_t visits = 0; __block BOOL resumed = NO; NSDictionary *next = nil; NSMutableString *log = [NSMutableString string];
        (void)FLScanStoreInodes(50000000, checkpoint, @"volume", 1049600, ^NSString *(uint64_t inode) {
            ++visits; if (inode == older) resumed = YES; return nil;
        }, ^NSTimeInterval { return (double)visits; }, &next, log);
        check(resumed && [next[@"next"] unsignedLongLongValue] == older - 1024 && [log containsString:@"time budget reached"], @"Older sweep did not resume or timeout checkpoint was lost");
    });
    test(@"Stale and malformed descending checkpoints are ignored", ^{
        uint64_t upper = FLInodeScanUpperBound(16);
        for (NSDictionary *checkpoint in @[
            @{@"schema":@2, @"context":@"other-volume", @"upper":@(upper), @"next":@100},
            @{@"schema":@2, @"context":@"volume", @"upper":@(upper), @"next":@100.5},
            @{@"schema":@2, @"context":@"volume", @"upper":@(upper), @"next":@(-1)},
            @{@"context":@"volume", @"next":@100}]) {
            NSMutableString *log = [NSMutableString string];
            (void)FLScanStoreInodes(16, checkpoint, @"volume", 0, ^NSString *(uint64_t inode) { (void)inode; return nil; }, ^NSTimeInterval { return 0; }, NULL, log);
            check([log containsString:@"older sweep new"], @"Invalid checkpoint affected search progress");
        }
    });
    return passed;
}
