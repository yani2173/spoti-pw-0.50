#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../performance/SGLightRendering.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
@interface TestVisualizerModel : NSObject
@property(nonatomic) BOOL running, listening, videoPlaying;
@property(nonatomic) BOOL visible, accessAllowed;
@property(nonatomic) NSInteger updates, invalidations;
@property(nonatomic, strong) id frame;
@property(nonatomic, copy) void (^updated)(void);
- (void)updateLink;
@end
@implementation TestVisualizerModel
- (void)setRunning:(BOOL)run {
    if (_running == run) return;
    _running = run;
    [self updateLink];
}
- (void)updateLink {
    self.updates++;
    BOOL run = self.running && self.visible && self.accessAllowed;
    if (self.listening && !run) self.invalidations++;
    self.listening = run;
    self.videoPlaying = run;
    if (self.updated) self.updated();
}
@end
@interface SGVisualizerView : TestVisualizerModel
@end
@implementation SGVisualizerView
@end

@interface TestDecorations : NSObject
@property(nonatomic, strong) id payload;
@property(nonatomic) BOOL value, animated;
@property(nonatomic) float dim;
- (void)setArtwork:(id)art animated:(BOOL)animated;
- (void)setColor:(id)color animated:(BOOL)animated;
- (void)show:(BOOL)shown animated:(BOOL)animated;
- (void)setLyricsUp:(BOOL)up animated:(BOOL)animated;
- (void)dimFrom:(float)dim animated:(BOOL)animated;
@end
@implementation TestDecorations
- (void)setArtwork:(id)art animated:(BOOL)animated { self.payload = art; self.animated = animated; }
- (void)setColor:(id)color animated:(BOOL)animated { self.payload = color; self.animated = animated; }
- (void)show:(BOOL)shown animated:(BOOL)animated { self.value = shown; self.animated = animated; }
- (void)setLyricsUp:(BOOL)up animated:(BOOL)animated { self.value = up; self.animated = animated; }
- (void)dimFrom:(float)dim animated:(BOOL)animated { self.dim = dim; self.animated = animated; }
@end
@interface SGRWarpLayer : TestDecorations
@property(nonatomic) BOOL pendingAnimated, consumedAnimated;
@property(nonatomic) NSInteger consumes;
- (void)takePending;
@end
@implementation SGRWarpLayer
- (void)takePending { self.consumedAnimated = self.pendingAnimated; self.consumes++; }
@end
@interface SGRPlayerAnimatedView : TestDecorations
@property(nonatomic, strong) id clip;
@property(nonatomic) uint64_t generation;
@property(nonatomic) NSInteger leaving, drops, accepted, crossfades;
- (void)dropLeaving;
- (void)fadeIn:(id)clip generation:(uint64_t)revision;
@end
@implementation SGRPlayerAnimatedView
- (void)dropLeaving { self.drops++; self.leaving = 0; }
- (void)fadeIn:(id)clip generation:(uint64_t)revision {
    if (self.clip != clip || self.generation != revision) return;
    self.accepted++;
    if (self.leaving) self.crossfades++;
}
@end
@interface SGRPlayerVisualizerHost : TestDecorations
@end
@implementation SGRPlayerVisualizerHost
@end

static SGVisualizerView *view(BOOL run) {
    SGVisualizerView *v = [SGVisualizerView new];
    v.visible = YES;
    v.accessAllowed = YES;
    v.frame = @"current artwork";
    v.running = run;
    return v;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : @"normal";
        if ([mode isEqual:@"unsupported-visualizer"]) {
            Method m = class_getInstanceMethod(SGVisualizerView.class, @selector(setRunning:));
            class_addMethod(SGVisualizerView.class, @selector(setRunning:), method_getImplementation(m), "v24@0:8d16");
            SGInstallLightRendering(YES, NO, NO);
            SGVisualizerView *v = view(YES);
            check(v.running && v.listening, "unsupported visualizer signature skips all visualizer hooks");
            puts("PASS: unsupported visualizer is untouched");
            return 0;
        }
        if ([mode isEqual:@"seeded"]) {
            SGInstallLightRendering(YES, NO, NO);
            SGVisualizerView *v = view(YES);
            check(!v.running && !v.listening && !v.videoPlaying, "startup Light mode suppresses new processing");
            SGApplyLightRendering(NO, NO, NO);
            check(v.running && v.listening, "startup owner request is restored");
            puts("PASS: startup Light mode rendering");
            return 0;
        }
        SGInstallLightRendering(NO, NO, NO);
        SGVisualizerView *active = view(YES), *paused = view(NO);
        [paused updateLink];
        TestVisualizerModel *unrelated = [TestVisualizerModel new];
        unrelated.visible = YES;
        unrelated.accessAllowed = YES;
        unrelated.running = YES;
        check(active.running && active.listening && active.videoPlaying, "normal mode preserves original processing");
        SGApplyLightRendering(YES, NO, NO);
        check(!active.running && !active.listening && !active.videoPlaying && active.invalidations == 1,
              "Light mode stops the pipeline, audio analysis and video input using the original update path");
        check(!paused.running && unrelated.listening, "owner pause and unrelated superclass are untouched");
        check([active.frame isEqual:@"current artwork"], "the existing static frame stays available");
        NSInteger updates = active.updates;
        SGApplyLightRendering(YES, NO, NO);
        active.running = YES;
        check(active.updates == updates && !active.running, "unchanged policy and repeated owner resumes avoid rebuilding processing");
        SGVisualizerView *late = view(YES);
        check(!late.running && !late.listening, "new views cannot start processing while light");
        late.running = NO;
        SGApplyLightRendering(NO, NO, NO);
        check(active.running && active.listening && !paused.running && !late.running,
              "leaving Light mode restores only the latest owner requests");
        active.accessAllowed = NO;
        [active updateLink];
        SGApplyLightRendering(YES, NO, NO);
        SGApplyLightRendering(NO, NO, NO);
        check(active.running && !active.listening, "restoration keeps the core's access checks");
        active.accessAllowed = YES;
        [active updateLink];
        SGApplyLightRendering(YES, YES, NO);
        SGApplyLightRendering(NO, YES, NO);
        check(!active.running && !active.listening, "turning light off cannot restart an inactive app");
        SGApplyLightRendering(NO, NO, NO);
        check(active.running && active.listening, "activation resumes requested processing");
        __weak SGVisualizerView *released;
        @autoreleasepool { SGVisualizerView *temporary = view(YES); released = temporary; }
        check(!released, "renderer registry retains no views");
        __block BOOL nested = NO;
        active.updated = ^{ if (!nested) { nested = YES; SGApplyLightRendering(NO, NO, NO); } };
        SGApplyLightRendering(YES, NO, NO);
        check(active.running && active.listening, "latest reentrant policy wins");
        active.updated = nil;

        SGApplyLightRendering(NO, NO, YES);
        check(!active.running && !active.listening && !active.videoPlaying, "player transitions stop analysis and video even without Light mode");
        SGVisualizerView *duringTransition = view(YES);
        check(!duringTransition.listening, "new visualizers cannot start mid-transition");
        SGApplyLightRendering(NO, NO, NO);
        check(active.listening && duringTransition.listening, "transition completion restores current owner requests");
        SGApplyLightRendering(NO, NO, YES);
        duringTransition.running = NO;
        SGApplyLightRendering(NO, YES, NO);
        check(!active.listening && !duringTransition.listening, "inactive interruption cannot resume processing");
        SGApplyLightRendering(NO, NO, NO);
        check(active.listening && !duringTransition.listening, "interrupted transitions preserve owner pauses");

        SGRWarpLayer *warp = [SGRWarpLayer new];
        SGRPlayerAnimatedView *cover = [SGRPlayerAnimatedView new];
        SGRPlayerVisualizerHost *host = [SGRPlayerVisualizerHost new];
        TestDecorations *other = [TestDecorations new];
        [warp setArtwork:@"first" animated:YES];
        check(warp.animated, "normal artwork animation is preserved");
        SGApplyLightRendering(YES, NO, NO);
        [warp setArtwork:@"new art" animated:YES];
        check(!warp.animated && [warp.payload isEqual:@"new art"], "artwork updates without a background crossfade");
        warp.pendingAnimated = YES;
        [warp takePending];
        check(!warp.consumedAnimated && warp.consumes == 1, "late pending artwork cannot re-enable fades");
        [cover setColor:@"blue" animated:YES];
        check(!cover.animated && [cover.payload isEqual:@"blue"], "color updates keep their content without animation");
        [cover show:YES animated:YES];
        check(cover.value && !cover.animated, "cover visibility still updates immediately");
        [cover setLyricsUp:YES animated:YES];
        check(cover.value && !cover.animated, "lyrics layout state still updates immediately");
        [cover dimFrom:0.75f animated:YES];
        check(cover.dim == 0.75f && !cover.animated, "float dimming argument is preserved");
        [host show:YES animated:YES];
        check(host.value && !host.animated, "visualizer host opacity changes without fading");
        [host setLyricsUp:NO animated:YES];
        check(!host.value && !host.animated, "visualizer host keeps the requested lyric layout");
        [other show:YES animated:YES];
        check(other.animated, "other classes keep their animations");
        cover.clip = @"current";
        cover.generation = 10;
        cover.leaving = 2;
        [cover fadeIn:cover.clip generation:9];
        [cover fadeIn:@"old" generation:10];
        check(cover.leaving == 2 && cover.drops == 0 && cover.accepted == 0,
              "stale readiness callbacks cannot remove current artwork layers");
        [cover fadeIn:cover.clip generation:10];
        check(!cover.leaving && cover.drops == 1 && cover.accepted == 1 && cover.crossfades == 0,
              "a ready current clip drops old video layers before showing without a crossfade");
        SGApplyLightRendering(NO, NO, NO);
        [cover show:NO animated:YES];
        check(!cover.value && cover.animated, "normal animations return after Light mode");
        [cover show:YES animated:NO];
        check(!cover.animated, "owner-disabled animations stay disabled");
        warp.pendingAnimated = YES;
        [warp takePending];
        check(warp.consumedAnimated, "pending artwork fades are preserved outside Light mode");
        cover.leaving = 1;
        [cover fadeIn:cover.clip generation:10];
        check(cover.leaving == 1 && cover.crossfades == 1, "normal clip crossfade behavior returns");
        puts("PASS: lighter rendering, owner state, inactivity, access, static frames, weak lifetime and decorative transitions");
    }
    return 0;
}
