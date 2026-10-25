//
//  Mirage Wallpaper
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

#import "VideoRendererEngine.h"
#import "VideoManifest.h"
#include <cstdio>
#include <cstdlib>

static void Check(BOOL value, const char *message) {
    if (value) return;
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
}

static BOOL Wait(BOOL (^condition)(void), double seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        Check(argc == 2, "fixture directory");
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSString *directory = [@(argv[1]) stringByAppendingPathComponent:@"base"];
        NSError *error = nil;
        VRVideoManifest *manifest = [VRVideoManifest loadFromDirectory:directory error:&error];
        Check(manifest != nil, "temporary fixture loads");
        VRVideoEngineConfig config = [VRVideoRendererEngine defaultConfig];
        config.muted = YES;
        VRVideoRendererEngine *owner = [[VRVideoRendererEngine alloc]
            initWithFrame:NSMakeRect(0, 0, 16, 16) config:config];
        __block BOOL decoded = NO;
        __block NSInteger ends = 0;
        owner.firstFrameReadyBlock = ^{ decoded = YES; };
        owner.videoDidEndBlock = ^{ ends += 1; };
        NSMutableArray<NSWindow *> *windows = [NSMutableArray array];
        for (int index = 0; index < 2; index++) {
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40 + index * 202, 40, 192, 108)
                styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            window.releasedWhenClosed = NO;
            window.alphaValue = 1;
            VRVideoRendererEngine *view = [[VRVideoRendererEngine alloc]
                initWithFrame:window.contentView.bounds config:config playbackOwner:owner];
            Check(view.player == owner.player, "presentation reuses the exact player instance");
            window.contentView = view;
            [window orderFrontRegardless];
            [windows addObject:window];
        }
        Check([owner openWallpaper:manifest error:&error], "video opens");
        Check(Wait(^BOOL {
            return decoded && ((VRVideoRendererEngine *)windows[0].contentView).presentationReady &&
                ((VRVideoRendererEngine *)windows[1].contentView).presentationReady;
        }, 12), "both independent layers present video");
        Check(Wait(^BOOL { return ends >= 2; }, 7), "shared layers survive multiple loop transitions");
        Check(Wait(^BOOL {
            double time = CMTimeGetSeconds(owner.player.currentTime);
            return time > 0.3 && time < 1.5;
        }, 3), "pause after a frame in the new loop has been presented");
        [owner pause];
        for (NSWindow *window in windows) {
            AVPlayerLayer *layer = (AVPlayerLayer *)window.contentView.layer.sublayers.firstObject;
            Check(Wait(^BOOL {
                CVPixelBufferRef buffer = [layer copyDisplayedPixelBuffer];
                if (!buffer) return NO;
                CVPixelBufferRelease(buffer);
                return YES;
            }, 2), "both layers retain an actual displayed pixel buffer");
        }
        NSWindow *removed = windows.firstObject;
        [removed close];
        removed.contentView = nil;
        [windows removeObjectAtIndex:0];
        removed = nil;
        [owner play];
        const double before = CMTimeGetSeconds(owner.player.currentTime);
        Check(Wait(^BOOL { return fabs(CMTimeGetSeconds(owner.player.currentTime) - before) > 0.1; }, 3),
              "releasing one presentation does not pause or empty its owner");
        Check(((VRVideoRendererEngine *)windows[0].contentView).presentationReady,
              "remaining presentation survives removal");
        [owner pause];
        for (NSWindow *window in windows) [window close];
        puts("SharedVideoPresentationRegression: passed");
    }
    return 0;
}
