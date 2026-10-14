#import "SGPerformance.h"
#import <objc/message.h>
#import <objc/runtime.h>
#ifdef SG_PERFORMANCE_TEST
#import "../tests/PerformanceUIKitStubs.h"
#else
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#endif

// An add-on for the verified official 0.50.0 kit, not a replacement spotifyglass.dylib.
// Its SGRKaraokeView.startLink passes self as the display link target (see README.md).
// The run loop retains the link and the link retains its target; this proxy holds the view weakly.
@interface SGPerfDisplayTarget : NSObject
@property (nonatomic, weak) id target;
@property (nonatomic, weak) CADisplayLink *link;
@property (nonatomic) BOOL ownerPaused;
- (void)tick:(CADisplayLink *)link;
@end

static BOOL sg_inactive;
static Class sg_lyricsClass;
static NSHashTable<SGPerfDisplayTarget *> *sg_targets;
static CADisplayLink *(*sg_factory)(id, SEL, id, SEL);
static void (*sg_pause)(id, SEL, BOOL);
static char sg_proxyKey;

static void pauseTarget(SGPerfDisplayTarget *target) {
    CADisplayLink *link = target.link;
    if (link && !link.isPaused) sg_pause(link, @selector(setPaused:), YES);
}

@implementation SGPerfDisplayTarget
- (void)tick:(CADisplayLink *)link {
    id target = self.target;
    if (!target) {
        [link invalidate];
        return;
    }
    if (sg_inactive) {
        pauseTarget(self);
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(target, @selector(tick));
}
@end

static CADisplayLink *displayLink(id cls, SEL cmd, id target, SEL selector) {
    // Everything except this exact lyrics callback uses Apple's original factory unchanged.
    if (!NSThread.isMainThread || ![target isKindOfClass:sg_lyricsClass] || selector != @selector(tick))
        return sg_factory(cls, cmd, target, selector);
    SGPerfDisplayTarget *proxy = [SGPerfDisplayTarget new];
    proxy.target = target;
    CADisplayLink *link = sg_factory(cls, cmd, proxy, @selector(tick:));
    proxy.link = link;
    proxy.ownerPaused = link.isPaused;
    if (link) objc_setAssociatedObject(link, &sg_proxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sg_targets addObject:proxy];
    // WillResignActive can arrive while UIApplication still reports Active. The notification wins.
    if (sg_inactive || UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        pauseTarget(proxy);
    return link;
}

static void setPaused(id link, SEL cmd, BOOL paused) {
    SGPerfDisplayTarget *proxy = objc_getAssociatedObject(link, &sg_proxyKey);
    if (proxy) {
        // Keep the owner's requested pause even if it changes while the app is inactive.
        proxy.ownerPaused = paused;
        paused = paused || sg_inactive;
    }
    sg_pause(link, cmd, paused);
}

static void setActive(BOOL active) {
    sg_inactive = !active;
    // A setter observer can create another link. Enumerate a snapshot so re-entrancy is safe.
    for (SGPerfDisplayTarget *target in sg_targets.allObjects) {
        if (!active) pauseTarget(target);
        else if (target.link) sg_pause(target.link, @selector(setPaused:), target.ownerPaused);
    }
}

static void notificationActive(BOOL active) {
    if (NSThread.isMainThread) setActive(active);
    else dispatch_async(dispatch_get_main_queue(), ^{ setActive(active); });
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
        if (!factory || !paused) return;
        sg_targets = [NSHashTable weakObjectsHashTable];
        sg_factory = (CADisplayLink *(*)(id, SEL, id, SEL))method_getImplementation(factory);
        sg_pause = (void (*)(id, SEL, BOOL))method_getImplementation(paused);
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
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
        method_setImplementation(paused, (IMP)setPaused);
        method_setImplementation(factory, (IMP)displayLink);
        NSLog(@"[spoti-perf] 0.50.0 lyrics: weak display targets and inactive suspension installed");
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
