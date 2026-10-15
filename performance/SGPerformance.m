#import "SGPerformance.h"
#import "SGPerfSettings.h"
#import "SGPerfABI.h"
#import "SGLightRendering.h"
#import "SGLyricsTiming.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#ifdef SG_PERFORMANCE_TEST
#import "../tests/PerformanceUIKitStubs.h"
#else
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#endif

// An add-on for the verified official 0.51.0 kit, not a replacement spotifyglass.dylib.
// Its SGRKaraokeView.startLink passes self as the display link target (see README.md).
// The run loop retains the link and the link retains its target; this proxy holds the view weakly.
@interface SGPerfDisplayTarget : NSObject
@property (nonatomic, weak) id target;
@property (nonatomic, strong) id retainedTicker;
@property (nonatomic, weak) CADisplayLink *link;
@property (nonatomic) BOOL ownerPaused;
@property (nonatomic) BOOL takesLink;
- (void)tick:(CADisplayLink *)link;
@end

@interface SGPerfCoverState : NSObject
@property (nonatomic) BOOL requestedPlaying;
@end
@implementation SGPerfCoverState
@end

// The view owns this sentinel, but the sentinel only references links weakly. Even an owner-paused
// link must be invalidated when its view goes away: it cannot reach the next tick to clean itself up.
@interface SGPerfViewLifetime : NSObject
@property (nonatomic, strong) NSHashTable<CADisplayLink *> *links;
@end

@implementation SGPerfViewLifetime
- (void)dealloc {
    NSArray<CADisplayLink *> *links = _links.allObjects;
    void (^invalidate)(void) = ^{
        for (CADisplayLink *link in links) [link invalidate];
    };
    if (NSThread.isMainThread) invalidate();
    else dispatch_async(dispatch_get_main_queue(), invalidate);
}
@end

static BOOL sg_inactive;
static BOOL sg_transitioning;
static BOOL sg_tracking;
static NSUInteger sg_trackingDepth;
static CFRunLoopTimerRef sg_trackingRecovery;
static BOOL sg_lightMode;
static BOOL sg_manualLightMode;
static BOOL sg_automaticLightMode;
static BOOL sg_lowPower;
static BOOL sg_thermalLimited;
static NSProcessInfoThermalState sg_thermalState;
static Class sg_lyricsClass;
static Class sg_warpTickerClass;
static Class sg_visualizerTickerClass;
static NSHashTable<SGPerfDisplayTarget *> *sg_targets;
static NSHashTable *sg_animatedCovers;
static CADisplayLink *(*sg_factory)(id, SEL, id, SEL);
static void (*sg_pause)(id, SEL, BOOL);
static void (*sg_invalidate)(id, SEL);
static char sg_proxyKey;
static char sg_lifetimeKey;
static char sg_coverKey;
static ptrdiff_t sg_coverPlayingOffset;
static void (*sg_coverPlaying)(id, SEL, BOOL);
static void (*sg_coverWindow)(id, SEL);
static void (*sg_coverClip)(id, SEL, id);
static atomic_uint_fast64_t sg_activityGeneration;
static atomic_uint_fast64_t sg_transitionGeneration;

static BOOL suspended(void) { return sg_inactive || sg_transitioning; }
static BOOL decorativeSuspended(void) { return suspended() || sg_tracking; }

NSString *const SGPerformanceLightModeKey = @"spotifyglass.performance.lightMode";
NSString *const SGPerformanceAutomaticLightModeKey = @"spotifyglass.performance.automaticLightMode";

static BOOL desiredLightMode(void) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    sg_manualLightMode = [store boolForKey:SGPerformanceLightModeKey];
    sg_automaticLightMode = [store boolForKey:SGPerformanceAutomaticLightModeKey];
    NSProcessInfo *process = NSProcessInfo.processInfo;
    sg_lowPower = process.lowPowerModeEnabled;
    sg_thermalState = process.thermalState;
    if (sg_thermalState >= NSProcessInfoThermalStateSerious) sg_thermalLimited = YES;
    else if (sg_thermalState == NSProcessInfoThermalStateNominal) sg_thermalLimited = NO;
    // Keep a heat-triggered reduction through Fair until Nominal, avoiding repeated toggling.
    return sg_manualLightMode || (sg_automaticLightMode && (sg_lowPower || sg_thermalLimited));
}

NSString *SGPerformanceLightModeStatus(void) {
    if (sg_manualLightMode) return @"Light · Manual";
    if (!sg_lightMode) return @"Normal";
    if (sg_lowPower) return @"Light · Low Power";
    if (sg_thermalState >= NSProcessInfoThermalStateSerious) return @"Light · Heat";
    return @"Light · Cooling";
}

static BOOL targetSuspended(SGPerfDisplayTarget *proxy) {
    return suspended() || ((sg_lightMode || sg_tracking) && proxy.takesLink);
}

static BOOL coverIsPlaying(id view) {
    // Read the verified one-byte BOOL directly: KVC boxes an NSNumber and repeats
    // property lookup during every policy sweep and clip handoff.
    unsigned char playing;
    const char *bytes = (__bridge const void *)view;
    memcpy(&playing, bytes + sg_coverPlayingOffset, sizeof(playing));
    return playing != 0;
}

static SGPerfCoverState *coverState(id view) {
    SGPerfCoverState *state = objc_getAssociatedObject(view, &sg_coverKey);
    if (!state) {
        state = [SGPerfCoverState new];
        state.requestedPlaying = coverIsPlaying(view);
        objc_setAssociatedObject(view, &sg_coverKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sg_animatedCovers addObject:view];
    }
    return state;
}

static void applyCoverState(id view) {
    SGPerfCoverState *state = coverState(view);
    BOOL playing = state.requestedPlaying && !sg_lightMode && !decorativeSuspended();
    if (coverIsPlaying(view) != playing)
        sg_coverPlaying(view, NSSelectorFromString(@"setPlaying:"), playing);
}

static void setCoverPlaying(id view, SEL cmd, BOOL playing) {
    if (!NSThread.isMainThread) { sg_coverPlaying(view, cmd, playing); return; }
    coverState(view).requestedPlaying = playing;
    sg_coverPlaying(view, cmd, playing && !sg_lightMode && !decorativeSuspended());
}

static void coverMovedToWindow(id view, SEL cmd) {
    sg_coverWindow(view, cmd);
    if (NSThread.isMainThread) applyCoverState(view);
}

static void showCoverClip(id view, SEL cmd, id clip) {
    if (NSThread.isMainThread) applyCoverState(view);
    sg_coverClip(view, cmd, clip);
}

static void pauseTarget(SGPerfDisplayTarget *target) {
    CADisplayLink *link = target.link;
    if (link && !link.isPaused) sg_pause(link, @selector(setPaused:), YES);
}

static void applyState(SGPerfDisplayTarget *proxy) {
    CADisplayLink *link = proxy.link;
    if (!link) return;
    if (!proxy.target) { [link invalidate]; return; }
    BOOL paused = proxy.ownerPaused || targetSuspended(proxy);
    if (link.isPaused != paused) sg_pause(link, @selector(setPaused:), paused);
}

@implementation SGPerfDisplayTarget
- (void)tick:(CADisplayLink *)link {
    id target = self.target;
    if (!target) {
        [link invalidate];
        return;
    }
    if (targetSuspended(self)) {
        pauseTarget(self);
        return;
    }
    if (self.takesLink) ((void (*)(id, SEL, id))objc_msgSend)(target, @selector(tick:), link);
    else ((void (*)(id, SEL))objc_msgSend)(target, @selector(tick));
}
@end

static CADisplayLink *displayLink(id cls, SEL cmd, id target, SEL selector) {
    BOOL lyrics = [target isKindOfClass:sg_lyricsClass] && selector == @selector(tick);
    Class clsOfTarget = object_getClass(target);
    BOOL ticker = selector == @selector(tick:) &&
        ((sg_warpTickerClass && clsOfTarget == sg_warpTickerClass) ||
         (sg_visualizerTickerClass && clsOfTarget == sg_visualizerTickerClass));
    // Only ABI-verified mod callbacks are wrapped. Spotify and other targets pass through.
    if (!NSThread.isMainThread || (!lyrics && !ticker))
        return sg_factory(cls, cmd, target, selector);
    SGPerfDisplayTarget *proxy = [SGPerfDisplayTarget new];
    proxy.target = target;
    proxy.takesLink = ticker;
    // The GPU tickers already reference their owners weakly. Some are retained only by the link;
    // preserve that ownership rather than introducing a weak target which immediately disappears.
    if (ticker) proxy.retainedTicker = target;
    CADisplayLink *link = sg_factory(cls, cmd, proxy, @selector(tick:));
    if (!link) return nil;
    proxy.link = link;
    proxy.ownerPaused = link.isPaused;
    objc_setAssociatedObject(link, &sg_proxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (lyrics) {
        SGPerfViewLifetime *lifetime = objc_getAssociatedObject(target, &sg_lifetimeKey);
        if (!lifetime) {
            lifetime = [SGPerfViewLifetime new];
            lifetime.links = [NSHashTable weakObjectsHashTable];
            objc_setAssociatedObject(target, &sg_lifetimeKey, lifetime, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [lifetime.links addObject:link];
    }
    [sg_targets addObject:proxy];
    // WillResignActive can arrive while UIApplication still reports Active. The notification wins.
    if (targetSuspended(proxy) || UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        pauseTarget(proxy);
    return link;
}

static void setPaused(id link, SEL cmd, BOOL paused) {
    SGPerfDisplayTarget *proxy = objc_getAssociatedObject(link, &sg_proxyKey);
    if (proxy) {
        // Keep the owner's requested pause even if it changes while the app is inactive.
        proxy.ownerPaused = paused;
        paused = paused || targetSuspended(proxy);
    }
    sg_pause(link, cmd, paused);
}

static void invalidateLink(id link, SEL cmd) {
    sg_invalidate(link, cmd);
    // Release the retained ticker as Apple's invalidate releases the original target, even if its
    // owner keeps the invalidated link object around. Also remove it from state sweeps immediately.
    if (objc_getAssociatedObject(link, &sg_proxyKey))
        objc_setAssociatedObject(link, &sg_proxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// UIKit tracks scroll/drag interaction in this public run-loop mode. Observe it once,
// rather than replacing Spotify's scroll delegates or traversing views on every frame.
static void setTracking(BOOL tracking) {
    if (sg_tracking == tracking) return;
    sg_tracking = tracking;
    SGApplyLightRendering(sg_lightMode, sg_inactive, sg_transitioning || sg_tracking);
    for (id view in sg_animatedCovers.allObjects) applyCoverState(view);
    for (SGPerfDisplayTarget *target in sg_targets.allObjects) applyState(target);
}

static void installTrackingObserver(void) {
    CFRunLoopRef loop = CFRunLoopGetMain();
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
        kCFRunLoopEntry | kCFRunLoopExit, true, 0,
        ^(CFRunLoopObserverRef observation, CFRunLoopActivity activity) {
            (void)observation;
            if (activity == kCFRunLoopEntry) {
                ++sg_trackingDepth;
                setTracking(YES);
                return;
            }
            if (sg_trackingDepth) --sg_trackingDepth;
            if (sg_trackingDepth) return;
            // Tracking loops can exit between input events. A single default-mode timer
            // coalesces those exits and waits for 120 ms of settled interaction. It cannot
            // run in tracking mode, and nested default loops cannot resume an outer drag.
            CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.12;
            if (sg_trackingRecovery) {
                CFRunLoopTimerSetNextFireDate(sg_trackingRecovery, deadline);
                return;
            }
            sg_trackingRecovery = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
                deadline, 0, 0, 0, ^(CFRunLoopTimerRef timer) {
                    (void)timer;
                    CFRelease(sg_trackingRecovery);
                    sg_trackingRecovery = NULL;
                    if (!sg_trackingDepth) setTracking(NO);
                    // Otherwise the outer tracking exit schedules recovery again.
                });
            if (sg_trackingRecovery)
                CFRunLoopAddTimer(loop, sg_trackingRecovery, kCFRunLoopDefaultMode);
            else setTracking(NO);
        });
    if (!observer) return;
    CFRunLoopAddObserver(loop, observer, (__bridge CFStringRef)UITrackingRunLoopMode);
    CFRelease(observer); // The run loop owns the observer for the process lifetime.
}

static void refreshLightMode(void);

static void setActive(BOOL active) {
    sg_inactive = !active;
    // A suspended process may miss a power/thermal event. Read current conditions before resuming.
    if (active) refreshLightMode();
    if (!active) {
        sg_transitioning = NO;
        atomic_fetch_add_explicit(&sg_transitionGeneration, 1, memory_order_relaxed);
    }
    SGApplyLightRendering(sg_lightMode, sg_inactive, sg_transitioning || sg_tracking);
    // A setter observer can create another link. Enumerate a snapshot so re-entrancy is safe.
    // Read the current state for each link. A setter observer can post another app notification;
    // the latest notification must win for the remainder of this snapshot too.
    for (SGPerfDisplayTarget *target in sg_targets.allObjects) applyState(target);
    for (id view in sg_animatedCovers.allObjects) applyCoverState(view);
}

static void refreshLightMode(void) {
    BOOL on = desiredLightMode();
    if (on == sg_lightMode) return;
    sg_lightMode = on;
    SGApplyLightRendering(sg_lightMode, sg_inactive, sg_transitioning || sg_tracking);
    for (SGPerfDisplayTarget *target in sg_targets.allObjects) applyState(target);
    for (id view in sg_animatedCovers.allObjects) applyCoverState(view);
}

void SGSetLightMode(BOOL on) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    if ([store boolForKey:SGPerformanceLightModeKey] != on)
        [store setBool:on forKey:SGPerformanceLightModeKey];
    if (NSThread.isMainThread) refreshLightMode();
    else dispatch_async(dispatch_get_main_queue(), ^{ refreshLightMode(); });
}

void SGSetAutomaticLightMode(BOOL on) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    if ([store boolForKey:SGPerformanceAutomaticLightModeKey] != on)
        [store setBool:on forKey:SGPerformanceAutomaticLightModeKey];
    if (NSThread.isMainThread) refreshLightMode();
    else dispatch_async(dispatch_get_main_queue(), ^{ refreshLightMode(); });
}

static void notificationTransition(BOOL transitioning) {
    uint_fast64_t generation = atomic_fetch_add_explicit(&sg_transitionGeneration, 1, memory_order_relaxed) + 1;
    void (^apply)(void) = ^{
        if (atomic_load_explicit(&sg_transitionGeneration, memory_order_relaxed) != generation) return;
        sg_transitioning = transitioning && !sg_inactive;
        SGApplyLightRendering(sg_lightMode, sg_inactive, sg_transitioning || sg_tracking);
        for (id view in sg_animatedCovers.allObjects) applyCoverState(view);
        for (SGPerfDisplayTarget *target in sg_targets.allObjects) applyState(target);
        if (sg_transitioning) {
            // Normal completion comes from the player's transition coordinator, including a
            // cancelled swipe. Recover if upstream never sends its end notification.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (atomic_load_explicit(&sg_transitionGeneration, memory_order_relaxed) != generation) return;
                sg_transitioning = NO;
                SGApplyLightRendering(sg_lightMode, sg_inactive, sg_transitioning || sg_tracking);
                for (id view in sg_animatedCovers.allObjects) applyCoverState(view);
                for (SGPerfDisplayTarget *target in sg_targets.allObjects) applyState(target);
            });
        }
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

static Class tickerClass(NSString *name) {
    Class cls = NSClassFromString(name);
    Method method = class_getInstanceMethod(cls, @selector(tick:));
    if (!method || method_getNumberOfArguments(method) != 3) return Nil;
    char result[16] = {0}, argument[16] = {0};
    if (method) {
        method_getReturnType(method, result, sizeof(result));
        method_getArgumentType(method, 2, argument, sizeof(argument));
    }
    return method && result[0] == 'v' && argument[0] == '@' && method_getNumberOfArguments(method) == 3 ? cls : Nil;
}

static void notificationActive(BOOL active) {
    uint_fast64_t generation = atomic_fetch_add_explicit(&sg_activityGeneration, 1, memory_order_relaxed) + 1;
    void (^apply)(void) = ^{
        // An off-main notification can be queued before a newer main-thread notification.
        if (atomic_load_explicit(&sg_activityGeneration, memory_order_relaxed) == generation)
            setActive(active);
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

void SGInstallPerformance(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_lyricsClass = NSClassFromString(@"SGRKaraokeView");
        Method tick = class_getInstanceMethod(sg_lyricsClass, @selector(tick));
        char result[16] = {0};
        if (tick) method_getReturnType(tick, result, sizeof(result));
        if (!tick || result[0] != 'v' || method_getNumberOfArguments(tick) != 2) return;
        Method factory = class_getClassMethod(CADisplayLink.class, @selector(displayLinkWithTarget:selector:));
        Method paused = class_getInstanceMethod(CADisplayLink.class, @selector(setPaused:));
        Method invalidated = class_getInstanceMethod(CADisplayLink.class, @selector(invalidate));
        if (!factory || !paused || !invalidated) return;
        sg_warpTickerClass = tickerClass(@"SGRWarpTicker");
        sg_visualizerTickerClass = tickerClass(@"SGVisualizerTicker");
        sg_targets = [NSHashTable weakObjectsHashTable];
        sg_animatedCovers = [NSHashTable weakObjectsHashTable];
        sg_lightMode = desiredLightMode();
        sg_inactive = UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
        sg_factory = (CADisplayLink *(*)(id, SEL, id, SEL))method_getImplementation(factory);
        sg_pause = (void (*)(id, SEL, BOOL))method_getImplementation(paused);
        sg_invalidate = (void (*)(id, SEL))method_getImplementation(invalidated);
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[NSUserDefaultsDidChangeNotification,
                                          NSProcessInfoPowerStateDidChangeNotification,
                                          NSProcessInfoThermalStateDidChangeNotification]) {
            [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                BOOL defaultsChanged = [note.name isEqualToString:NSUserDefaultsDidChangeNotification];
                void (^refresh)(void) = ^{
                    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
                    if (defaultsChanged &&
                        [store boolForKey:SGPerformanceLightModeKey] == sg_manualLightMode &&
                        [store boolForKey:SGPerformanceAutomaticLightModeKey] == sg_automaticLightMode) return;
                    refreshLightMode();
                };
                if (NSThread.isMainThread) refresh();
                else dispatch_async(dispatch_get_main_queue(), refresh);
            }];
        }
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil
                            queue:nil usingBlock:^(NSNotification *note) {
            (void)note;
            notificationActive(NO);
        }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                            queue:nil usingBlock:^(NSNotification *note) {
            (void)note;
            notificationActive(YES);
        }];
        [center addObserverForName:@"spotifyglass.playerTransition" object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;
            notificationTransition(YES);
        }];
        [center addObserverForName:@"spotifyglass.playerTransitionEnded" object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;
            notificationTransition(NO);
        }];
        method_setImplementation(invalidated, (IMP)invalidateLink);
        method_setImplementation(paused, (IMP)setPaused);
        method_setImplementation(factory, (IMP)displayLink);
        Class coverClass = NSClassFromString(@"SGRPlayerAnimatedView");
        Ivar playing = class_getInstanceVariable(coverClass, "_playing");
        const char *type = playing ? ivar_getTypeEncoding(playing) : "";
        if (playing && type && (strcmp(type, "B") == 0 || strcmp(type, "c") == 0) &&
            SGPerfHasMethod(coverClass, NSSelectorFromString(@"setPlaying:"), 'v', "B") &&
            SGPerfHasMethod(coverClass, NSSelectorFromString(@"didMoveToWindow"), 'v', "") &&
            SGPerfHasMethod(coverClass, NSSelectorFromString(@"showClip:"), 'v', "@")) {
            sg_coverPlayingOffset = ivar_getOffset(playing);
            Method setter = class_getInstanceMethod(coverClass, NSSelectorFromString(@"setPlaying:"));
            Method window = class_getInstanceMethod(coverClass, NSSelectorFromString(@"didMoveToWindow"));
            Method clip = class_getInstanceMethod(coverClass, NSSelectorFromString(@"showClip:"));
            sg_coverPlaying = (void (*)(id, SEL, BOOL))method_getImplementation(setter);
            sg_coverWindow = (void (*)(id, SEL))method_getImplementation(window);
            sg_coverClip = (void (*)(id, SEL, id))method_getImplementation(clip);
            SGPerfReplaceMethod(coverClass, NSSelectorFromString(@"setPlaying:"), (IMP)setCoverPlaying);
            SGPerfReplaceMethod(coverClass, NSSelectorFromString(@"didMoveToWindow"), (IMP)coverMovedToWindow);
            SGPerfReplaceMethod(coverClass, NSSelectorFromString(@"showClip:"), (IMP)showCoverClip);
        }
        SGInstallLightRendering(sg_lightMode, sg_inactive, sg_transitioning || sg_tracking);
        installTrackingObserver();
        SGInstallLyricsTiming();
        SGInstallPerformanceSettings();
        NSLog(@"[spoti-perf] 0.51.0: lyrics lifecycle and player-transition suspension installed");
    });
}

#ifndef SG_PERFORMANCE_TEST
__attribute__((constructor)) static void install(void) {
    @autoreleasepool {
        if (NSThread.isMainThread) SGInstallPerformance();
        else dispatch_async(dispatch_get_main_queue(), ^{ SGInstallPerformance(); });
    }
}
#endif
