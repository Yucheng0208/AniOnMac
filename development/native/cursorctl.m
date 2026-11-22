// Native command-line cursor backend. Private API signatures and identifiers
// loaded dynamically from macOS. No helper installation required.
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <math.h>

typedef int (*ConnectionFn)(void);
typedef CGError (*RegisterFn)(int, const char *, bool, bool, CGSize, CGPoint, NSUInteger, CGFloat, CFArrayRef, int *);
typedef CGError (*CopyFn)(int, const char *, CGSize *, CGPoint *, NSUInteger *, CGFloat *, CFArrayRef *);
typedef CGError (*CoreCopyFn)(int, int, CFArrayRef *, CGSize *, CGPoint *, NSUInteger *, CGFloat *);
static ConnectionFn connection;
static RegisterFn registerCursor;
static CopyFn copyCursor;
static CoreCopyFn coreCopy;

static void fail(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(1);
}

static NSArray *identifiers(void) {
    return @[@"com.apple.coregraphics.Arrow", @"com.apple.cursor.13",
             @"com.apple.coregraphics.IBeam", @"com.apple.coregraphics.Wait"];
}

static NSDictionary *aliases(void) {
    return @{@"com.apple.coregraphics.Arrow": @"com.apple.coregraphics.ArrowS",
             @"com.apple.coregraphics.IBeam": @"com.apple.coregraphics.IBeamS"};
}

static NSDictionary *effectiveCursors(NSDictionary *input, BOOL modern) {
    NSMutableDictionary *result = [input mutableCopy];
    if (modern) {
        for (NSString *old in aliases()) {
            NSString *name = aliases()[old];
            if (!result[name] && result[old]) result[name] = result[old];
            [result removeObjectForKey:old];
        }
    }
    return result;
}

static void loadAPI(void) {
    dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY | RTLD_GLOBAL);
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL);
    connection = (ConnectionFn)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    registerCursor = (RegisterFn)dlsym(RTLD_DEFAULT, "CGSRegisterCursorWithImages");
    copyCursor = (CopyFn)dlsym(RTLD_DEFAULT, "CGSCopyRegisteredCursorImages");
    coreCopy = (CoreCopyFn)dlsym(RTLD_DEFAULT, "CoreCursorCopyImages");
    if (!connection || !registerCursor || !copyCursor || !coreCopy)
        fail(@"Required private cursor API is unavailable. No cursors changed.");
}

// The private registration API rejects >24 frames, but macOS itself registers
// longer animations (the native Wait cursor has 30). Snapshots/backups of the
// live system therefore may exceed the registration limit.
enum { kRegisterMaxFrames = 24, kSnapshotMaxFrames = 128 };

static NSDictionary *readCapeLimited(NSString *path, NSUInteger maxFrames) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) fail(@"Cannot read cape file.");
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if (![value isKindOfClass:NSDictionary.class]) fail(@"Invalid cape plist.");
    id cursors = value[@"Cursors"];
    if (![cursors isKindOfClass:NSDictionary.class]) fail(@"Expected cursor dictionary.");
    NSMutableSet *allowed = [NSMutableSet setWithArray:identifiers()];
    [allowed addObjectsFromArray:aliases().allValues];
    for (NSString *key in cursors)
        if (![allowed containsObject:key]) fail(@"Unsupported cursor identifier.");
    if ([cursors count] < 1 || [cursors count] > 6) fail(@"Expected one to four cursor modes (with optional aliases).");
    for (NSString *key in cursors) {
        id c = cursors[key];
        if (![c isKindOfClass:NSDictionary.class]) fail(@"Missing cursor role.");
        for (NSString *field in @[@"FrameCount", @"FrameDuration", @"PointsWide", @"PointsHigh", @"HotSpotX", @"HotSpotY"])
            if (![c[field] isKindOfClass:NSNumber.class] || !isfinite([c[field] doubleValue])) fail(@"Invalid numeric cursor field.");
        double w = [c[@"PointsWide"] doubleValue], h = [c[@"PointsHigh"] doubleValue];
        double x = [c[@"HotSpotX"] doubleValue], y = [c[@"HotSpotY"] doubleValue];
        double n = [c[@"FrameCount"] doubleValue], duration = [c[@"FrameDuration"] doubleValue];
        if (n < 1 || n > maxFrames || floor(n) != n || w <= 0 || h <= 0 || w > 512 || h > 512 || x < 0 || y < 0 || x >= w || y >= h || duration < 0 || (n > 1 && duration <= 0))
            fail(@"Cursor dimensions, timing or hotspot out of bounds.");
        id reps = c[@"Representations"];
        if (![reps isKindOfClass:NSArray.class] || [reps count] == 0) fail(@"Missing image representations.");
        for (id data in reps) {
            if (![data isKindOfClass:NSData.class]) fail(@"Invalid representation data.");
            NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:data];
            if (!rep || rep.pixelsHigh % (NSInteger)n || rep.pixelsWide <= 0)
                fail(@"Invalid vertically stacked animation image.");
        }
    }
    return cursors;
}

static NSDictionary *readCape(NSString *path) { return readCapeLimited(path, kRegisterMaxFrames); }

// Uniformly subsample a vertically stacked animation so it fits the
// registration limit while keeping the original cycle duration.
static NSDictionary *fitFrames(NSDictionary *c) {
    NSUInteger n = [c[@"FrameCount"] unsignedIntegerValue];
    if (n <= kRegisterMaxFrames) return c;
    NSUInteger stride = (n + kRegisterMaxFrames - 1) / kRegisterMaxFrames;
    NSUInteger outFrames = n / stride;
    NSMutableArray *reps = [NSMutableArray array];
    for (NSData *data in c[@"Representations"]) {
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:data];
        CGImageRef image = rep.CGImage;
        if (!image) return nil;
        size_t w = CGImageGetWidth(image), fh = CGImageGetHeight(image) / n;
        CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(NULL, w, fh * outFrames, 8, w * 4, color, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(color);
        if (!ctx) return nil;
        for (NSUInteger step = 0; step < outFrames; step++) {
            CGImageRef frame = CGImageCreateWithImageInRect(image, CGRectMake(0, step * stride * fh, w, fh));
            CGContextDrawImage(ctx, CGRectMake(0, (outFrames - 1 - step) * fh, w, fh), frame);
            CGImageRelease(frame);
        }
        CGImageRef out = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:out] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        CGImageRelease(out);
        if (!png) return nil;
        [reps addObject:png];
    }
    NSMutableDictionary *r = [c mutableCopy];
    r[@"FrameCount"] = @(outFrames);
    r[@"FrameDuration"] = @([c[@"FrameDuration"] doubleValue] * stride);
    r[@"Representations"] = reps;
    return r;
}

static BOOL applyOne(NSString *key, NSDictionary *c) {
    NSMutableArray *images = [NSMutableArray array];
    for (NSData *data in c[@"Representations"]) {
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:data];
        if (!rep.CGImage) return NO;
        [images addObject:(__bridge id)rep.CGImage];
    }
    int seed = 0;
    CGError err = registerCursor(connection(), key.UTF8String, true, true,
        CGSizeMake([c[@"PointsWide"] doubleValue], [c[@"PointsHigh"] doubleValue]),
        CGPointMake([c[@"HotSpotX"] doubleValue], [c[@"HotSpotY"] doubleValue]),
        [c[@"FrameCount"] unsignedIntegerValue], [c[@"FrameDuration"] doubleValue],
        (__bridge CFArrayRef)images, &seed);
    if (err) fprintf(stderr, "%s: CoreGraphics error %d\n", key.UTF8String, err);
    return err == 0;
}

static NSDictionary *snapshot(NSArray *keys) {
    // Initialize AppKit's relevant cursor representations, without setting them.
    (void)[NSCursor arrowCursor]; (void)[NSCursor IBeamCursor]; (void)[NSCursor pointingHandCursor];
    NSMutableDictionary *saved = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        CGSize size = CGSizeZero; CGPoint hotspot = CGPointZero;
        NSUInteger count = 0; CGFloat duration = 0; CFArrayRef images = NULL;
        CGError err;
        if ([key isEqualToString:@"com.apple.cursor.13"])
            err = coreCopy(connection(), 13, &images, &size, &hotspot, &count, &duration);
        else
            err = copyCursor(connection(), key.UTF8String, &size, &hotspot, &count, &duration, &images);
        if (err || !images || !CFArrayGetCount(images)) {
            if (images) CFRelease(images);
            fprintf(stderr, "Cannot read %s (error %d).\n", key.UTF8String, err);
            return nil;
        }
        NSMutableArray *reps = [NSMutableArray array];
        for (id image in (__bridge NSArray *)images) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)image];
            NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            if (!png) { CFRelease(images); return nil; }
            [reps addObject:png];
        }
        CFRelease(images);
        saved[key] = @{@"PointsWide": @(size.width), @"PointsHigh": @(size.height),
                       @"HotSpotX": @(hotspot.x), @"HotSpotY": @(hotspot.y),
                       @"FrameCount": @(count), @"FrameDuration": @(duration), @"Representations": reps};
    }
    return saved;
}

// Readback verifies geometry and timing, not on-screen selection or pixel identity.
static BOOL metadataMatches(NSDictionary *expected, NSDictionary *actual) {
    for (NSString *field in @[@"PointsWide", @"PointsHigh", @"HotSpotX", @"HotSpotY", @"FrameCount", @"FrameDuration"]) {
        if (!actual[field] || fabs([expected[field] doubleValue] - [actual[field] doubleValue]) > 0.0001)
            return NO;
    }
    return YES;
}

static BOOL verify(NSDictionary *target) {
    NSDictionary *actual = snapshot(target.allKeys);
    if (!actual) return NO;
    BOOL matched = YES;
    for (NSString *key in [target.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        BOOL ok = metadataMatches(target[key], actual[key]);
        printf("%s: %s; size %.3fx%.3f pt, hotspot (%.3f, %.3f), frames %lu, duration %.6f s\n",
            key.UTF8String, ok ? "metadata MATCH" : "metadata MISMATCH",
            [actual[key][@"PointsWide"] doubleValue], [actual[key][@"PointsHigh"] doubleValue],
            [actual[key][@"HotSpotX"] doubleValue], [actual[key][@"HotSpotY"] doubleValue],
            [actual[key][@"FrameCount"] unsignedLongValue], [actual[key][@"FrameDuration"] doubleValue]);
        if (!ok) matched = NO;
    }
    return matched;
}

static BOOL saveBackup(NSDictionary *before, NSString *path, BOOL replacing, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"Cursors": before}
        format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:path options:(replacing ? NSDataWritingAtomic : NSDataWritingWithoutOverwriting) error:error];
}

#include "native_defaults.h"

#ifndef CURSORCTL_TEST
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) fail(@"Usage: cursorctl doctor | validate FILE | plan FILE | inspect | verify FILE | defaults-export FILE | apply FILE BACKUP | apply-replace FILE BACKUP | restore BACKUP");
        NSString *command = @(argv[1]);
        if ([command isEqualToString:@"defaults-export"] && argc == 3) {
            NSDictionary *data = @{@"Cursors": nativeDefaults(), @"CapeName": @"macOS 原生游標", @"Source": @"Local Apple system resources"};
            NSData *plist = [NSPropertyListSerialization dataWithPropertyList:data format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
            NSError *error = nil;
            if (![plist writeToFile:@(argv[2]) options:NSDataWritingWithoutOverwriting error:&error]) fail(error.localizedDescription);
            (void)readCape(@(argv[2]));
            puts("Exported native cursors from local Apple resources. No system registrations changed.");
            return 0;
        }
        BOOL modern = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26;
        if ([command isEqualToString:@"doctor"] && argc == 2) {
            loadAPI();
            puts("Native cursor backend: private API symbols available (not proof of visible behavior).");
            printf("macOS 26+ alias routing: %s\n", modern ? "ArrowS / IBeamS" : "legacy Arrow / IBeam");
            return 0;
        }
        if ([command isEqualToString:@"inspect"] && argc == 2) {
            loadAPI();
            NSMutableDictionary *roles = [NSMutableDictionary dictionary];
            for (NSString *key in identifiers()) roles[key] = @{};
            NSArray *keys = effectiveCursors(roles, modern).allKeys;
            NSDictionary *current = snapshot(keys);
            if (!current) fail(@"Inspection failed; no cursors changed.");
            for (NSString *key in [keys sortedArrayUsingSelector:@selector(compare:)]) {
                NSMutableDictionary *c = [current[key] mutableCopy];
                [c removeObjectForKey:@"Representations"];
                printf("%s: %s\n", key.UTF8String, c.description.UTF8String);
            }
            puts("Read-only inspection. No cursor registrations changed.");
            return 0;
        }
        if ([command isEqualToString:@"validate"] && argc == 3) {
            (void)readCape(@(argv[2]));
            puts("Cursor data decoded by native AppKit. No cursors changed.");
            return 0;
        }
        if ([command isEqualToString:@"plan"] && argc == 3) {
            NSDictionary *target = effectiveCursors(readCape(@(argv[2])), modern);
            for (NSString *key in [target.allKeys sortedArrayUsingSelector:@selector(compare:)]) puts(key.UTF8String);
            return 0;
        }
        if ([command isEqualToString:@"verify"] && argc == 3) {
            NSDictionary *target = effectiveCursors(readCape(@(argv[2])), modern);
            loadAPI();
            BOOL ok = verify(target);
            puts("Readback checks metadata only. Visible appearance and animation still require observation.");
            return ok ? 0 : 2;
        }
        BOOL replacing = [command isEqualToString:@"apply-replace"] && argc == 4;
        BOOL applying = ([command isEqualToString:@"apply"] && argc == 4) || replacing;
        BOOL restoring = [command isEqualToString:@"restore"] && argc == 3;
        if (!applying && !restoring) fail(@"Invalid arguments. Use doctor, validate FILE, plan FILE, inspect, verify FILE, apply FILE BACKUP, or restore BACKUP.");
        NSDictionary *input = restoring ? readCapeLimited(@(argv[2]), kSnapshotMaxFrames) : readCape(@(argv[2]));
        NSMutableDictionary *target = [effectiveCursors(input, modern) mutableCopy];
        if (restoring) {
            for (NSString *key in target.allKeys) {
                NSDictionary *fitted = fitFrames(target[key]);
                if (!fitted) fail(@"Cannot resample backup animation. No cursors changed.");
                target[key] = fitted;
            }
        }
        if (restoring && modern && (input[@"com.apple.coregraphics.Arrow"] || input[@"com.apple.coregraphics.IBeam"]))
            puts("Legacy backup: routing stored Arrow/IBeam images to ArrowS/IBeamS on macOS 26+. This restores stored images, not an unrecorded historical alias state.");
        loadAPI();
        NSArray *keys = [target.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSDictionary *before = snapshot(keys);
        if (!before) fail(@"Cannot back up all target cursors. No cursors changed.");
        if (applying) {
            NSString *path = @(argv[3]);
            NSError *error = nil;
            if (!saveBackup(before, path, replacing, &error)) fail([NSString stringWithFormat:@"Cannot save backup: %@", error]);
            (void)readCapeLimited(path, kSnapshotMaxFrames);
            printf("Backup saved: %s\n", path.UTF8String);
        }
        BOOL success = YES;
        for (NSString *key in keys) {
            if (!applyOne(key, target[key])) { success = NO; break; }
        }
        if (success) success = verify(target);
        if (!success) {
            BOOL ok = YES;
            NSMutableDictionary *rollback = [NSMutableDictionary dictionary];
            for (NSString *key in keys) {
                NSDictionary *fitted = fitFrames(before[key]);
                if (!fitted || !applyOne(key, fitted)) ok = NO;
                else rollback[key] = fitted;
            }
            if (ok) ok = verify(rollback);
            fail(ok ? @"Apply/readback failed; prior metadata restored. Verify appearance." : @"Apply or rollback verification failed. Use saved backup to restore.");
        }
        puts("Selected cursor registrations and metadata readbacks succeeded. Verify visible appearance, animation and click alignment in your apps.");
        return 0;
    }
}
#endif
