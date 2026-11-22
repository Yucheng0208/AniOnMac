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

        // A live snapshot can hold Apple's 30-frame Wait; backups must accept it
        // and restore must resample it under the 24-frame registration limit.
        NSUInteger tall = 30;
        NSBitmapImageRep *strip = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:4 pixelsHigh:4 * tall
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSDictionary *live = @{@"PointsWide": @24, @"PointsHigh": @24, @"HotSpotX": @12, @"HotSpotY": @11,
                               @"FrameCount": @(tall), @"FrameDuration": @(1.0 / 60),
                               @"Representations": @[[strip representationUsingType:NSBitmapImageFileTypePNG properties:@{}]]};
        NSString *snap = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert(saveBackup(@{@"com.apple.coregraphics.Wait": live}, snap, NO, &error));
        assert(readCapeLimited(snap, kSnapshotMaxFrames).count == 1);
        [NSFileManager.defaultManager removeItemAtPath:snap error:NULL];
        NSDictionary *fitted = fitFrames(live);
        assert([fitted[@"FrameCount"] unsignedIntegerValue] == 15);
        assert(fabs([fitted[@"FrameDuration"] doubleValue] - 2.0 / 60) < 1e-9);
        assert([NSBitmapImageRep imageRepWithData:fitted[@"Representations"][0]].pixelsHigh == 4 * 15);
        assert(fitFrames(wait) == wait);
        puts("PASS: legacy/new aliases, explicit alias priority, backup round-trip, readback mismatch detection. No system cursor calls.");
    }
    return 0;
}
