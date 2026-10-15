#import "SGLightRendering.h"
#import "SGPerfABI.h"
#import <objc/message.h>

@protocol SGLightVisualizer <NSObject>
@property(nonatomic, readonly) BOOL running;
@end

@interface SGLightVisualizerState : NSObject
@property(nonatomic) BOOL requestedRunning;
@end
@implementation SGLightVisualizerState
@end

static BOOL light, appInactive, interactionSuspended;
static NSHashTable *visualizers;
static char visualizerKey;
static void (*setRunningOriginal)(id, SEL, BOOL);
static void (*updateLinkOriginal)(id, SEL);

static SGLightVisualizerState *visualizerState(id<SGLightVisualizer> view) {
    SGLightVisualizerState *state = objc_getAssociatedObject(view, &visualizerKey);
    if (!state) {
        state = [SGLightVisualizerState new];
        state.requestedRunning = view.running;
        objc_setAssociatedObject(view, &visualizerKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [visualizers addObject:view];
    }
    return state;
}

static BOOL requestedRun(id view) {
    return visualizerState(view).requestedRunning && !light && !appInactive && !interactionSuspended;
}

static void applyVisualizer(id<SGLightVisualizer> view) {
    BOOL run = requestedRun(view);
    if (view.running != run) setRunningOriginal(view, sel_registerName("setRunning:"), run);
}

static void setVisualizerRunning(id view, SEL cmd, BOOL run) {
    if (NSThread.isMainThread) {
        visualizerState(view).requestedRunning = run;
        run = run && !light && !appInactive && !interactionSuspended;
    }
    setRunningOriginal(view, cmd, run);
}

static void updateVisualizerLink(id<SGLightVisualizer> view, SEL cmd) {
    if (NSThread.isMainThread) {
        BOOL run = requestedRun(view);
        if (view.running != run) {
            // The verified original setter changes _running and calls updateLink: the
            // nested hook sees the corrected value and invokes the core exactly once.
            setRunningOriginal(view, sel_registerName("setRunning:"), run);
            return;
        }
    }
    updateLinkOriginal(view, cmd);
}

void SGApplyLightRendering(BOOL lightMode, BOOL inactive, BOOL interactionBusy) {
    if (!NSThread.isMainThread) return;
    if (light == lightMode && appInactive == inactive && interactionSuspended == interactionBusy) return;
    light = lightMode;
    appInactive = inactive;
    interactionSuspended = interactionBusy;
    for (id view in visualizers.allObjects) applyVisualizer(view);
}

static BOOL animate(BOOL requested) {
    return requested && (!NSThread.isMainThread || !light);
}

static void installObjectAnimation(Class cls, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!SGPerfHasMethod(cls, selector, 'v', "@B")) return;
    void (*original)(id, SEL, id, BOOL) = (void *)method_getImplementation(class_getInstanceMethod(cls, selector));
    IMP wrapper = imp_implementationWithBlock(^(id view, id value, BOOL animated) {
        original(view, selector, value, animate(animated));
    });
    SGPerfReplaceMethod(cls, selector, wrapper);
}

static void installBoolAnimation(Class cls, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!SGPerfHasMethod(cls, selector, 'v', "BB")) return;
    void (*original)(id, SEL, BOOL, BOOL) = (void *)method_getImplementation(class_getInstanceMethod(cls, selector));
    IMP wrapper = imp_implementationWithBlock(^(id view, BOOL value, BOOL animated) {
        original(view, selector, value, animate(animated));
    });
    SGPerfReplaceMethod(cls, selector, wrapper);
}

void SGInstallLightRendering(BOOL lightMode, BOOL inactive, BOOL interactionBusy) {
    if (!NSThread.isMainThread) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        light = lightMode;
        appInactive = inactive;
        interactionSuspended = interactionBusy;
        visualizers = [NSHashTable weakObjectsHashTable];
        Class visualizer = NSClassFromString(@"SGVisualizerView");
        if (SGPerfHasMethod(visualizer, sel_registerName("running"), 'B', "") &&
            SGPerfHasMethod(visualizer, sel_registerName("setRunning:"), 'v', "B") &&
            SGPerfHasMethod(visualizer, sel_registerName("updateLink"), 'v', "")) {
            setRunningOriginal = (void *)method_getImplementation(class_getInstanceMethod(visualizer, sel_registerName("setRunning:")));
            updateLinkOriginal = (void *)method_getImplementation(class_getInstanceMethod(visualizer, sel_registerName("updateLink")));
            SGPerfReplaceMethod(visualizer, sel_registerName("setRunning:"), (IMP)setVisualizerRunning);
            SGPerfReplaceMethod(visualizer, sel_registerName("updateLink"), (IMP)updateVisualizerLink);
        }

        Class warp = NSClassFromString(@"SGRWarpLayer");
        installObjectAnimation(warp, @"setArtwork:animated:");
        // An artwork conversion queued before Light mode may finish afterwards. Clamp
        // its pending fade at consumption as well, keeping the newly decoded artwork.
        Ivar pending = class_getInstanceVariable(warp, "_pendingAnimated");
        if (pending && SGPerfTypeMatches(ivar_getTypeEncoding(pending)[0], 'B') &&
            [warp accessInstanceVariablesDirectly] && SGPerfHasMethod(warp, sel_registerName("takePending"), 'v', "")) {
            void (*original)(id, SEL) = (void *)method_getImplementation(class_getInstanceMethod(warp, sel_registerName("takePending")));
            IMP wrapper = imp_implementationWithBlock(^(id layer) {
                if (NSThread.isMainThread && light) [layer setValue:@NO forKey:@"pendingAnimated"];
                original(layer, sel_registerName("takePending"));
            });
            SGPerfReplaceMethod(warp, sel_registerName("takePending"), wrapper);
        }

        Class cover = NSClassFromString(@"SGRPlayerAnimatedView");
        Class host = NSClassFromString(@"SGRPlayerVisualizerHost");
        installObjectAnimation(cover, @"setColor:animated:");
        for (NSString *name in @[@"show:animated:", @"setLyricsUp:animated:"]) {
            installBoolAnimation(cover, name);
            installBoolAnimation(host, name);
        }
        if (SGPerfHasMethod(cover, sel_registerName("dimFrom:animated:"), 'v', "fB")) {
            void (*original)(id, SEL, float, BOOL) = (void *)method_getImplementation(class_getInstanceMethod(cover, sel_registerName("dimFrom:animated:")));
            IMP wrapper = imp_implementationWithBlock(^(id view, float value, BOOL animated) {
                original(view, sel_registerName("dimFrom:animated:"), value, animate(animated));
            });
            SGPerfReplaceMethod(cover, sel_registerName("dimFrom:animated:"), wrapper);
        }
        // Ready callbacks carry a generation. Only the current, ready replacement may
        // drop old video layers; a stale callback must retain the core's no-op behavior.
        Ivar generation = class_getInstanceVariable(cover, "_generation");
        if (generation && !strcmp(ivar_getTypeEncoding(generation), "Q") && [cover accessInstanceVariablesDirectly] &&
            SGPerfHasMethod(cover, sel_registerName("clip"), '@', "") &&
            SGPerfHasMethod(cover, sel_registerName("dropLeaving"), 'v', "") &&
            SGPerfHasMethod(cover, sel_registerName("fadeIn:generation:"), 'v', "@Q")) {
            void (*original)(id, SEL, id, uint64_t) = (void *)method_getImplementation(class_getInstanceMethod(cover, sel_registerName("fadeIn:generation:")));
            IMP wrapper = imp_implementationWithBlock(^(id view, id clip, uint64_t revision) {
                if (NSThread.isMainThread && light && clip &&
                    ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("clip")) == clip &&
                    [[view valueForKey:@"generation"] unsignedLongLongValue] == revision)
                    ((void (*)(id, SEL))objc_msgSend)(view, sel_registerName("dropLeaving"));
                original(view, sel_registerName("fadeIn:generation:"), clip, revision);
            });
            SGPerfReplaceMethod(cover, sel_registerName("fadeIn:generation:"), wrapper);
        }
    });
}
