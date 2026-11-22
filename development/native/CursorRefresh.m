#import <AppKit/AppKit.h>
#import <dlfcn.h>
static BOOL hoveringButton = NO;
static int selectCurrentCursor(void) {
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL);
    int (*connection)(void) = dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    CGError (*selectCursor)(int, const char *, int *) = dlsym(RTLD_DEFAULT, "CGSSetRegisteredCursor");
    if (!connection || !selectCursor) return -1;
    if (hoveringButton) [NSCursor.pointingHandCursor set]; else [NSCursor.arrowCursor set];
    const char *name = hoveringButton ? "com.apple.cursor.13" :
        (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "com.apple.coregraphics.ArrowS" : "com.apple.coregraphics.Arrow");
    int seed = 0;
    return selectCursor(connection(), name, &seed);
}
int MeowRefreshCursor(void) {
    for (NSWindow *window in NSApp.windows)
        if (window.contentView) [window invalidateCursorRectsForView:window.contentView];
    return selectCurrentCursor();
}
void MeowHoverCursor(int inside) {
    hoveringButton = inside != 0;
    (void)selectCurrentCursor();
}
