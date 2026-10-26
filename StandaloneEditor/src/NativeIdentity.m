// Mirage Wallpaper
// Copyright © 2026 王孝慈. All rights reserved.

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

static IMP originalIcon;
static IMP originalTitle;
static NSImage *mirageIcon;
static char restoreFrameKey;
static IMP originalWindowEvent;
static IMP originalCursor;
static __weak NSWindow *consumeMouseUp;

static void zoomEditor(void) {
    for (NSWindow *window in NSApp.windows) {
        if (!window.visible || ![window.title isEqualToString:@"Mirage Editor"] || window.frame.size.width < 400) continue;
        NSValue *restore = objc_getAssociatedObject(window, &restoreFrameKey);
        NSRect target = window.screen.visibleFrame;
        if (restore && NSEqualRects(window.frame, target)) {
            target = restore.rectValue;
            objc_setAssociatedObject(window, &restoreFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            objc_setAssociatedObject(window, &restoreFrameKey, [NSValue valueWithRect:window.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [window setFrame:target display:YES];
        return;
    }
}

static NSCursor *edgeCursor(NSWindow *window) {
    if (!NSApp.active || ![window.title isEqualToString:@"Mirage Editor"]) return nil;
    NSPoint point = [window convertPointFromScreen:NSEvent.mouseLocation];
    NSRect bounds = window.contentView.frame;
    if (!NSPointInRect(point, NSInsetRect(bounds, -3, -3))) return nil;
    NSUInteger position = 0;
    if (point.x < NSMinX(bounds) + 5) position |= 2;
    else if (point.x > NSMaxX(bounds) - 5) position |= 8;
    if (point.y < NSMinY(bounds) + 5) position |= 4;
    else if (point.y > NSMaxY(bounds) - 5) position |= 1;
    if (!position) return nil;
    if (@available(macOS 15.0, *)) return [NSCursor frameResizeCursorFromPosition:position inDirections:NSCursorFrameResizeDirectionsAll];
    return position & (2 | 8) ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor;
}

static void setCursor(NSCursor *cursor, SEL selector) {
    NSCursor *edge = edgeCursor(NSApp.keyWindow);
    ((void (*)(id, SEL))originalCursor)(edge ?: cursor, selector);
}

static void windowEvent(id application, SEL selector, NSEvent *event) {
    NSWindow *window = event.window;
    if (event.type == NSEventTypeLeftMouseUp && consumeMouseUp == window) {
        consumeMouseUp = nil;
        return;
    }
    CGFloat top = NSMaxY(window.contentView.frame) - event.locationInWindow.y;
    if (event.type == NSEventTypeLeftMouseDown && event.clickCount == 2 &&
        [window.title isEqualToString:@"Mirage Editor"] &&
        event.locationInWindow.x >= 85 && top >= 5 && top < 38) {
        consumeMouseUp = window;
        zoomEditor();
        return;
    }
    ((void (*)(id, SEL, id))originalWindowEvent)(application, selector, event);
    if (event.type == NSEventTypeMouseMoved || event.type == NSEventTypeLeftMouseDragged) {
        NSCursor *edge = edgeCursor(window);
        if (edge) [edge set];
    }
}

static void setIcon(id app, SEL selector, NSImage *image) {
    ((void (*)(id, SEL, id))originalIcon)(app, selector, mirageIcon ?: image);
}

static void setTitle(id window, SEL selector, NSString *title) {
    if ([title isEqualToString:@"Wallpaper UI"] || [title containsString:@"Wallpaper Engine"])
        title = @"Mirage Editor";
    ((void (*)(id, SEL, id))originalTitle)(window, selector, title);
}

static void installIdentity(unsigned attempt) {
    if (!NSApp || !NSClassFromString(@"WineWindow")) {
        if (attempt < 200) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{ installIdentity(attempt + 1); });
        return;
    }
    NSString *icon = [NSBundle.mainBundle pathForResource:@"Mirage" ofType:@"icns"];
    mirageIcon = [[NSImage alloc] initWithContentsOfFile:icon];
    if (mirageIcon) {
        originalIcon = method_setImplementation(class_getInstanceMethod(NSApplication.class,
            @selector(setApplicationIconImage:)), (IMP)setIcon);
        NSApp.applicationIconImage = mirageIcon;
    }
    originalTitle = method_setImplementation(class_getInstanceMethod(NSWindow.class,
        @selector(setTitle:)), (IMP)setTitle);
    for (NSWindow *window in NSApp.windows) window.title = window.title;
    originalWindowEvent = method_setImplementation(class_getInstanceMethod(NSClassFromString(@"WineApplication"),
        @selector(sendEvent:)), (IMP)windowEvent);
    originalCursor = method_setImplementation(class_getInstanceMethod(NSCursor.class, @selector(set)), (IMP)setCursor);
    const char *token = getenv("MIRAGE_EDITOR_SESSION_TOKEN");
    if (token) {
        NSString *session = [NSString stringWithUTF8String:token];
        [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"cn.laobamac.Mirage.Editor.Zoom"
            object:session queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) { zoomEditor(); }];
    }
}

__attribute__((constructor)) static void initializeIdentity(void) {
    char path[4096]; uint32_t capacity = sizeof(path);
    if (_NSGetExecutablePath(path, &capacity) || !strstr(path, "Mirage WE Editor.app/")) return;
    dispatch_async(dispatch_get_main_queue(), ^{ installIdentity(0); });
}
