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
// Model the core's show path: hiding the overlay uncovers native track artwork.
@interface TestArtworkHost : TestDecorations
@property(nonatomic) BOOL shown, nativeCoverVisible;
@property(nonatomic, copy) NSString *artwork;
@property(nonatomic, copy) void (^shownChanged)(void);
@end
@implementation TestArtworkHost
- (instancetype)init {
    if ((self = [super init])) _nativeCoverVisible = YES;
    return self;
}
- (void)show:(BOOL)show animated:(BOOL)animated {
    [super show:show animated:animated];
    if (_shown == show) return;
    _shown = show;
    self.nativeCoverVisible = !show;
    if (self.shownChanged) self.shownChanged();
}
@end
@interface SGRPlayerAnimatedView : TestArtworkHost
@property(nonatomic, strong) id clip;
@property(nonatomic) uint64_t generation;
@property(nonatomic) NSInteger leaving, drops, accepted, crossfades;
- (void)clear:(BOOL)animated;
- (void)dropLeaving;
- (void)fadeIn:(id)clip generation:(uint64_t)revision;
@end
@implementation SGRPlayerAnimatedView
- (void)clear:(BOOL)animated {
    self.generation++;
    self.clip = nil;
    if (self.shown) [self show:NO animated:animated];
    else [self dropLeaving];
}
- (void)dropLeaving { self.drops++; self.leaving = 0; }
- (void)fadeIn:(id)clip generation:(uint64_t)revision {
    if (self.clip != clip || self.generation != revision) return;
    self.accepted++;
    [self show:YES animated:YES];
    if (self.leaving) self.crossfades++;
}
@end
@interface SGRPlayerVisualizerHost : TestArtworkHost
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
        if ([mode isEqual:@"unsupported-artwork"]) {
            for (Class cls in @[SGRPlayerAnimatedView.class, SGRPlayerVisualizerHost.class]) {
                Method method = class_getInstanceMethod(cls, @selector(shown));
                class_addMethod(cls, @selector(shown), method_getImplementation(method), "d16@0:8");
            }
            SGInstallLightRendering(YES, NO, NO);
            for (TestArtworkHost *v in @[[SGRPlayerAnimatedView new], [SGRPlayerVisualizerHost new]]) {
                [v show:YES animated:YES];
                check(v.value, "unsupported visibility ABI leaves show requests unchanged");
            }
            puts("PASS: unsupported artwork visibility ABI");
            return 0;
        }
        if ([mode isEqual:@"seeded"]) {
            SGInstallLightRendering(YES, NO, NO);
            SGVisualizerView *v = view(YES);
            check(!v.running && !v.listening && !v.videoPlaying, "startup Light mode suppresses new processing");
            SGRPlayerAnimatedView *cover = [SGRPlayerAnimatedView new];
            cover.clip = @"cached";
            [cover fadeIn:cover.clip generation:cover.generation];
            check(!cover.shown && cover.nativeCoverVisible, "saved Light mode shows artwork for cached clips immediately");
            SGApplyLightRendering(NO, NO, NO);
            check(cover.shown && !cover.nativeCoverVisible, "saved Light mode restores the current ready clip when disabled");
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
        check(!cover.shown && cover.nativeCoverVisible && !cover.animated, "Light mode reveals static cover instead of a frozen frame");
        [cover setLyricsUp:YES animated:YES];
        check(cover.value && !cover.animated, "lyrics layout state still updates immediately");
        [cover dimFrom:0.75f animated:YES];
        check(cover.dim == 0.75f && !cover.animated, "float dimming argument is preserved");
        [host show:YES animated:YES];
        check(!host.shown && host.nativeCoverVisible && !host.animated, "Light mode also reveals artwork behind the stopped visualizer");
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
        cover.artwork = @"song A";
        [cover show:YES animated:NO];
        [host show:YES animated:NO];
        SGApplyLightRendering(YES, NO, NO);
        check(!cover.shown && cover.nativeCoverVisible && !host.shown && host.nativeCoverVisible,
              "enabling Light mode hides already-visible animated layers");
        cover.artwork = @"song B";
        cover.clip = @"cached B";
        cover.generation++;
        [cover fadeIn:cover.clip generation:cover.generation];
        check(!cover.shown && [cover.artwork isEqual:@"song B"], "cached readiness cannot cover the new song's artwork");
        SGApplyLightRendering(NO, NO, NO);
        check(cover.shown && host.shown && [cover.clip isEqual:@"cached B"], "normal mode restores latest requested overlays");
        SGApplyLightRendering(YES, NO, NO);
        [cover clear:YES]; // Native clear skips show:NO because Light mode already hid it.
        [host show:NO animated:NO];
        SGApplyLightRendering(NO, NO, NO);
        check(!cover.shown && !host.shown && cover.nativeCoverVisible,
              "clearing or disabling an overlay while light cannot resurrect it later");
        [cover fadeIn:@"cached B" generation:cover.generation - 1];
        check(!cover.shown, "stale readiness after clear cannot resurrect an overlay");
        [cover show:YES animated:NO];
        SGApplyLightRendering(NO, NO, YES);
        check(cover.shown, "temporary scrolling/transition suspension keeps normal presentation");
        SGApplyLightRendering(NO, YES, NO);
        check(cover.shown, "app inactivity alone does not replace the requested presentation");
        SGApplyLightRendering(NO, NO, NO);
        __weak TestArtworkHost *released;
        @autoreleasepool {
            SGRPlayerAnimatedView *temporary = [SGRPlayerAnimatedView new];
            [temporary show:YES animated:NO];
            released = temporary;
        }
        check(released == nil, "visibility registry never retains a player view");
        __block BOOL changedPolicy = NO;
        cover.shownChanged = ^{
            if (!changedPolicy) { changedPolicy = YES; SGApplyLightRendering(NO, NO, NO); }
        };
        SGApplyLightRendering(YES, NO, NO);
        check(cover.shown, "a reentrant latest policy wins without leaving artwork stuck");
        cover.shownChanged = nil;
        puts("PASS: lighter rendering, owner state, inactivity, access, static frames, weak lifetime and decorative transitions");
    }
    return 0;
}
