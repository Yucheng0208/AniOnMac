#define CURSORCTL_TEST
#include "../native/cursorctl.m"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSDictionary *original = nativeDefaults();
        NSMutableDictionary *legacy = [original mutableCopy];
        for (NSString *old in aliases()) {
            NSString *alias = aliases()[old];
            if (legacy[alias]) { legacy[old] = legacy[alias]; [legacy removeObjectForKey:alias]; }
        }
        NSDictionary *modern = effectiveCursors(legacy, YES);
        assert(modern.count == 4);
        assert(!modern[@"com.apple.coregraphics.Arrow"]);
        assert(!modern[@"com.apple.coregraphics.IBeam"]);
        assert([modern[@"com.apple.coregraphics.ArrowS"] isEqual:legacy[@"com.apple.coregraphics.Arrow"]]);
        assert([modern[@"com.apple.coregraphics.IBeamS"] isEqual:legacy[@"com.apple.coregraphics.IBeam"]]);
        assert([effectiveCursors(legacy, NO) isEqual:legacy]);
        assert([effectiveCursors(modern, YES) isEqual:modern]);
        NSMutableDictionary *explicitAlias = [legacy mutableCopy];
        explicitAlias[@"com.apple.coregraphics.ArrowS"] = @{@"custom": @YES};
        assert([effectiveCursors(explicitAlias, YES)[@"com.apple.coregraphics.ArrowS"] isEqual:explicitAlias[@"com.apple.coregraphics.ArrowS"]]);

        NSDictionary *wait = modern[@"com.apple.coregraphics.Wait"];
        NSMutableDictionary *observed = [wait mutableCopy];
        observed[@"FrameDuration"] = @([wait[@"FrameDuration"] doubleValue] + 0.00000001);
        assert(metadataMatches(wait, observed));
        for (NSString *field in @[@"PointsWide", @"PointsHigh", @"HotSpotX", @"HotSpotY", @"FrameCount", @"FrameDuration"]) {
            observed = [wait mutableCopy];
            observed[field] = @([wait[field] doubleValue] + 1);
            assert(!metadataMatches(wait, observed));
        }
        assert(!metadataMatches(wait, @{}));
        // Backup uses actual aliases and is accepted without changing any live cursor.
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"Cursors": modern}
            format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
        assert([data writeToFile:path atomically:YES]);
        assert([readCape(path) isEqual:modern]);
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        NSString *backup = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSError *error = nil;
        assert(saveBackup(legacy, backup, NO, &error));
        assert(!saveBackup(modern, backup, NO, &error));
        assert([readCape(backup) isEqual:legacy]);
        assert(saveBackup(modern, backup, YES, &error));
        assert([readCape(backup) isEqual:modern]);
        assert(saveBackup(@{@"com.apple.coregraphics.Wait": wait}, backup, YES, &error));
        assert(readCape(backup).count == 1);
        [NSFileManager.defaultManager removeItemAtPath:backup error:NULL];
        puts("PASS: legacy/new aliases, explicit alias priority, backup round-trip, readback mismatch detection. No system cursor calls.");
    }
    return 0;
}
