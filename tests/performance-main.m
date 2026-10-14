#import "PerformanceUIKitStubs.h"
#import "../performance/SGPerformance.h"
#import <objc/message.h>
#import <objc/runtime.h>

static void require(BOOL condition, const char *message);
static BOOL nilFactory;
NSNotificationName const UIApplicationWillResignActiveNotification = @"UIApplicationWillResignActiveNotification";
NSNotificationName const UIApplicationDidBecomeActiveNotification = @"UIApplicationDidBecomeActiveNotification";
@implementation UIApplication
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    (void)url;
    (void)options;
    if (completion) completion(YES);
}
+ (instancetype)sharedApplication {
    static UIApplication *app;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ app = [UIApplication new]; });
    return app;
}
@end
@implementation CADisplayLink {
    id _target;
    SEL _selector;
    BOOL _invalidated;
}
@synthesize paused = _paused;
+ (instancetype)displayLinkWithTarget:(id)target selector:(SEL)selector {
    if (nilFactory) return nil;
    CADisplayLink *link = [self new];
    link->_target = target;
    link->_selector = selector;
    return link;
}
- (id)target { return _target; }
- (BOOL)invalidated { return _invalidated; }
- (void)setPaused:(BOOL)paused {
    _paused = paused;
    if (self.pauseObserver) self.pauseObserver(paused);
}
- (void)invalidate {
    require(NSThread.isMainThread, "managed links are invalidated on the main thread");
    _invalidated = YES;
    _target = nil;
}
- (void)fire {
    id target = _target;
    if (!self.paused && target) ((void (*)(id, SEL, id))objc_msgSend)(target, _selector, self);
}
@end
@interface SGRKaraokeView : NSObject
@property (nonatomic) NSInteger calls;
@property (nonatomic, strong) CADisplayLink *link;
- (void)tick;
@end
@implementation SGRKaraokeView
- (void)tick { self.calls++; }
@end
@interface OtherTarget : NSObject
- (void)tick;
@end
@implementation OtherTarget
- (void)tick {}
@end
@interface SGRWarpTicker : NSObject
@property (nonatomic) NSInteger calls;
@property (nonatomic, weak) CADisplayLink *lastLink;
- (void)tick:(CADisplayLink *)link;
@end
@implementation SGRWarpTicker
- (void)tick:(CADisplayLink *)link { self.calls++; self.lastLink = link; }
@end
@interface SGVisualizerTicker : SGRWarpTicker
@end
@implementation SGVisualizerTicker
@end
@interface SGTestAnimatedCoverModel : NSObject
@property (nonatomic) BOOL playing;
@property (nonatomic) BOOL clipPlaying;
@property (nonatomic) NSInteger windowMoves;
@property (nonatomic, strong) id lastClip;
- (void)didMoveToWindow;
- (void)showClip:(id)clip;
@end
@implementation SGTestAnimatedCoverModel
- (void)didMoveToWindow { self.windowMoves++; }
- (void)showClip:(id)clip { self.lastClip = clip; self.clipPlaying = self.playing; }
@end
@interface SGRPlayerAnimatedView : SGTestAnimatedCoverModel
@end
@implementation SGRPlayerAnimatedView
@end
@interface SGTestSettingsRowModel : NSObject
@property (nonatomic, copy) NSString *title, *subtitle, *key, *symbol;
@property (nonatomic) BOOL defaultOn;
@property (nonatomic, copy) void (^changed)(BOOL on);
@property (nonatomic, copy) void (^action)(void);
@end
@implementation SGTestSettingsRowModel
@end
@interface SGModRow : SGTestSettingsRowModel
@end
@implementation SGModRow
@end
@interface SGModSection : NSObject
@property (nonatomic, copy) NSString *title, *footer;
@property (nonatomic, copy) NSArray *rows;
@end
@implementation SGModSection
@end
@interface SGModPage : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray *sections;
@property (nonatomic) NSInteger adoptions;
- (void)adopt:(NSArray *)sections;
@end
@implementation SGModPage
- (void)adopt:(NSArray *)sections { self.sections = sections; self.adoptions++; }
@end
static void require(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static void notify(NSNotificationName name) {
    [NSNotificationCenter.defaultCenter postNotificationName:name object:nil];
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGPerformanceLightModeKey];
        if (argc > 1 && strcmp(argv[1], "unsupported-settings") == 0) {
            Method setter = class_getInstanceMethod(SGModRow.class, @selector(setChanged:));
            require(class_addMethod(SGModRow.class, @selector(setChanged:), method_getImplementation(setter), "v20@0:8B16"),
                    "test installs an incompatible settings signature");
            SGInstallPerformance();
            SGModPage *page = [SGModPage new];
            page.title = @"Chroma";
            [page adopt:@[]];
            require(page.sections.count == 0 && page.adoptions == 1, "unsupported settings ABI leaves the original page untouched");
            puts("PASS: unsupported settings signature guard");
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "unsupported-cover") == 0) {
            Method setter = class_getInstanceMethod(SGRPlayerAnimatedView.class, @selector(setPlaying:));
            require(class_addMethod(SGRPlayerAnimatedView.class, @selector(setPlaying:), method_getImplementation(setter), "v24@0:8d16"),
                    "test installs an incompatible cover signature");
            SGInstallPerformance();
            SGSetLightMode(YES);
            SGRPlayerAnimatedView *view = [SGRPlayerAnimatedView new];
            view.playing = YES;
            require(view.playing, "unsupported animated cover ABI is left untouched");
            SGSetLightMode(NO);
            puts("PASS: unsupported cover signature guard");
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "light-mode-seeded") == 0) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:SGPerformanceLightModeKey];
            SGInstallPerformance();
            SGRWarpTicker *ticker = [SGRWarpTicker new];
            CADisplayLink *gpu = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(tick:)];
            SGRKaraokeView *view = [SGRKaraokeView new];
            CADisplayLink *lyrics = [CADisplayLink displayLinkWithTarget:view selector:@selector(tick)];
            SGRPlayerAnimatedView *cover = [SGRPlayerAnimatedView new];
            cover.playing = YES;
            require(gpu.isPaused && !lyrics.isPaused && !cover.playing, "the saved Light mode applies to new GPU links and animated covers at startup");
            SGSetLightMode(NO);
            require(!gpu.isPaused && cover.playing, "saved Light mode can be disabled live");
            puts("PASS: saved Light mode at startup");
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "unsupported-ticker") == 0) {
            Method tick = class_getInstanceMethod(SGVisualizerTicker.class, @selector(tick:));
            class_addMethod(SGVisualizerTicker.class, @selector(tick:), method_getImplementation(tick), "v24@0:8d16");
            SGInstallPerformance();
            SGVisualizerTicker *ticker = [SGVisualizerTicker new];
            CADisplayLink *link = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(tick:)];
            require(link.target == ticker, "a ticker with an unsupported ABI is left untouched");
            puts("PASS: unsupported ticker signature guard");
            return 0;
        }
        if (argc > 1) {
            UIApplication.sharedApplication.applicationState = strcmp(argv[1], "background") == 0
                ? UIApplicationStateBackground : UIApplicationStateInactive;
            SGInstallPerformance();
            SGRKaraokeView *view = [SGRKaraokeView new];
            CADisplayLink *link = [CADisplayLink displayLinkWithTarget:view selector:@selector(tick)];
            require(link.isPaused, "installation while inactive immediately suspends new links");
            link.paused = NO;
            require(link.isPaused, "owner resume cannot bypass an initially inactive app");
            SGRWarpTicker *ticker = [SGRWarpTicker new];
            CADisplayLink *gpu = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(tick:)];
            gpu.paused = NO;
            require(gpu.isPaused, "initial inactive suspension also applies to GPU links");
            UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
            notify(UIApplicationDidBecomeActiveNotification);
            require(!link.isPaused, "the initially inactive link resumes on activation");
            require(!gpu.isPaused, "initially inactive GPU links resume on activation");
            puts("PASS: initially inactive installation");
            return 0;
        }
        SGInstallPerformance();
        SGInstallPerformance();
        SGRKaraokeView *view = [SGRKaraokeView new];
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:view selector:@selector(tick)];
        view.link = link;
        link.preferredFramesPerSecond = 120;
        [link fire];
        require(view.calls == 1, "callback reaches the original target exactly once");
        notify(UIApplicationWillResignActiveNotification);
        require(link.isPaused, "existing lyrics link pauses immediately");
        [link fire];
        require(view.calls == 1, "inactive lyrics do not tick");
        CADisplayLink *late = [CADisplayLink displayLinkWithTarget:view selector:@selector(tick)];
        require(late.isPaused, "a late link stays paused while UIApplication still reports Active");
        notify(UIApplicationDidBecomeActiveNotification);
        require(!link.isPaused && !late.isPaused, "links resume after becoming active");
        require(link.preferredFramesPerSecond == 120, "the requested frame rate is preserved");
        [link fire];
        require(view.calls == 2, "callbacks resume exactly once");
        link.paused = YES;
        notify(UIApplicationWillResignActiveNotification);
        notify(UIApplicationDidBecomeActiveNotification);
        require(link.isPaused, "a link paused by its owner stays paused");
        link.paused = NO;
        notify(UIApplicationWillResignActiveNotification);
        link.paused = YES;
        notify(UIApplicationDidBecomeActiveNotification);
        require(link.isPaused, "an owner pause requested while inactive is preserved");
        notify(UIApplicationWillResignActiveNotification);
        link.paused = NO;
        require(link.isPaused, "the owner cannot restart lyrics during inactive suspension");
        notify(UIApplicationDidBecomeActiveNotification);
        require(!link.isPaused, "an owner resume requested while inactive applies on activation");
        SGRKaraokeView *reentrant = [SGRKaraokeView new];
        link.pauseObserver = ^(BOOL paused) {
            if (paused && !reentrant.link)
                reentrant.link = [CADisplayLink displayLinkWithTarget:reentrant selector:@selector(tick)];
        };
        notify(UIApplicationWillResignActiveNotification);
        require(reentrant.link.isPaused, "a link created by a pause observer is safely suspended");
        notify(UIApplicationDidBecomeActiveNotification);
        require(!reentrant.link.isPaused, "the re-entrant link resumes without a collection mutation");
        link.pauseObserver = nil;
        NSMutableArray<SGRKaraokeView *> *nested = [NSMutableArray new];
        __block BOOL interruptedResume = NO;
        for (NSInteger i = 0; i < 10; i++) {
            SGRKaraokeView *item = [SGRKaraokeView new];
            item.link = [CADisplayLink displayLinkWithTarget:item selector:@selector(tick)];
            item.link.pauseObserver = ^(BOOL paused) {
                if (!paused && !interruptedResume) {
                    interruptedResume = YES;
                    notify(UIApplicationWillResignActiveNotification);
                }
            };
            [nested addObject:item];
        }
        notify(UIApplicationWillResignActiveNotification);
        notify(UIApplicationDidBecomeActiveNotification);
        require(interruptedResume, "test posted an inactive notification during resume");
        for (SGRKaraokeView *item in nested) {
            require(item.link.isPaused, "the latest nested notification wins for every link");
            item.link.pauseObserver = nil;
        }
        notify(UIApplicationDidBecomeActiveNotification);
        dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            notify(UIApplicationWillResignActiveNotification);
        });
        notify(UIApplicationDidBecomeActiveNotification);
        __block BOOL drainedNotifications = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ drainedNotifications = YES; });
        NSDate *notificationDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (!drainedNotifications && notificationDeadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        require(drainedNotifications && !link.isPaused,
                "a stale queued notification cannot overwrite a newer main-thread state");
        OtherTarget *other = [OtherTarget new];
        CADisplayLink *untouched = [CADisplayLink displayLinkWithTarget:other selector:@selector(tick)];
        require(untouched.target == other, "other targets retain Apple's original behavior");
        __weak SGRKaraokeView *released = view;
        view = nil;
        require(released == nil, "the original lyrics view can release while links exist");
        require(link.invalidated && late.invalidated, "all links invalidate immediately on view release");
        link.paused = NO;
        [link fire];
        require(link.invalidated, "an abandoned link invalidates itself");
        [late fire];
        require(late.invalidated, "every link of a released target invalidates itself");
        __weak CADisplayLink *releasedLink;
        @autoreleasepool {
            SGRKaraokeView *temporary = [SGRKaraokeView new];
            CADisplayLink *temporaryLink = [CADisplayLink displayLinkWithTarget:temporary selector:@selector(tick)];
            releasedLink = temporaryLink;
            temporaryLink = nil;
        }
        require(releasedLink == nil, "the registry does not retain display links");
        CADisplayLink *pausedOrphan;
        @autoreleasepool {
            SGRKaraokeView *temporary = [SGRKaraokeView new];
            pausedOrphan = [CADisplayLink displayLinkWithTarget:temporary selector:@selector(tick)];
            temporary.link = pausedOrphan;
            pausedOrphan.paused = YES;
        }
        require(pausedOrphan.invalidated, "owner-paused links clean up without another frame");
        __block SGRKaraokeView *backgroundReleased = [SGRKaraokeView new];
        CADisplayLink *backgroundLink = [CADisplayLink displayLinkWithTarget:backgroundReleased selector:@selector(tick)];
        dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            @autoreleasepool { backgroundReleased = nil; }
        });
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (!backgroundLink.invalidated && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        require(backgroundLink.invalidated, "off-main view release schedules link cleanup on main");
        nilFactory = YES;
        require([CADisplayLink displayLinkWithTarget:reentrant selector:@selector(tick)] == nil,
                "a failed original factory remains nil");
        nilFactory = NO;
        SGRWarpTicker *warp = [SGRWarpTicker new];
        SGVisualizerTicker *visualizer = [SGVisualizerTicker new];
        CADisplayLink *warpLink = [CADisplayLink displayLinkWithTarget:warp selector:@selector(tick:)];
        CADisplayLink *visualizerLink = [CADisplayLink displayLinkWithTarget:visualizer selector:@selector(tick:)];
        warpLink.preferredFramesPerSecond = 120;
        [warpLink fire];
        [visualizerLink fire];
        require(warp.calls == 1 && warp.lastLink == warpLink && visualizer.calls == 1,
                "GPU callbacks receive the original link exactly once");
        notify(@"spotifyglass.playerTransition");
        require(warpLink.isPaused && visualizerLink.isPaused && reentrant.link.isPaused,
                "GPU and lyrics links suspend during player transitions");
        [warpLink fire];
        require(warp.calls == 1, "GPU work cannot run during a transition");
        warpLink.paused = NO;
        require(warpLink.isPaused, "an owner resume cannot bypass transition suspension");
        visualizerLink.paused = YES;
        CADisplayLink *lateGpu = [CADisplayLink displayLinkWithTarget:warp selector:@selector(tick:)];
        require(lateGpu.isPaused, "a GPU link created mid-transition is suspended");
        notify(@"spotifyglass.playerTransitionEnded");
        require(!warpLink.isPaused && !lateGpu.isPaused && !reentrant.link.isPaused,
                "links resume at transition completion, including a cancelled swipe");
        require(visualizerLink.isPaused, "GPU owner pauses survive the transition");
        require(warpLink.preferredFramesPerSecond == 120, "normal GPU frame rates are preserved");
        [warpLink fire];
        require(warp.calls == 2 && warp.lastLink == warpLink, "GPU rendering resumes with the original link");
        notify(@"spotifyglass.playerTransition");
        notify(UIApplicationWillResignActiveNotification);
        notify(@"spotifyglass.playerTransitionEnded");
        require(warpLink.isPaused, "transition completion cannot resume rendering while inactive");
        notify(UIApplicationDidBecomeActiveNotification);
        require(!warpLink.isPaused, "returning to the app recovers interrupted transitions");
        dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            notify(@"spotifyglass.playerTransition");
        });
        notify(@"spotifyglass.playerTransitionEnded");
        drainedNotifications = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ drainedNotifications = YES; });
        notificationDeadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (!drainedNotifications && notificationDeadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        require(drainedNotifications && !warpLink.isPaused, "stale queued transition starts cannot pause completed transitions");
        __weak SGRWarpTicker *retainedOnlyByLink;
        CADisplayLink *transientLink;
        @autoreleasepool {
            SGRWarpTicker *transientTicker = [SGRWarpTicker new];
            retainedOnlyByLink = transientTicker;
            transientLink = [CADisplayLink displayLinkWithTarget:transientTicker selector:@selector(tick:)];
        }
        require(retainedOnlyByLink != nil, "the original link-owned GPU ticker stays alive");
        [transientLink fire];
        require(retainedOnlyByLink.calls == 1, "a link-owned ticker still receives callbacks");
        [transientLink invalidate];
        require(retainedOnlyByLink == nil, "invalidate releases the ticker while the link object is retained");
        SGModPage *root = [SGModPage new];
        root.title = @"Chroma";
        SGModSection *existing = [SGModSection new];
        existing.rows = @[];
        [root adopt:@[existing]];
        require(root.sections.count == 3 && root.sections.firstObject == existing && root.adoptions == 1,
                "the performance section is added without replacing original sections");
        SGModSection *performance = root.sections[1];
        SGModRow *light = performance.rows.firstObject;
        require([performance.title isEqualToString:@"Performance"] && [light.title isEqualToString:@"Light mode"] &&
                [light.key isEqualToString:SGPerformanceLightModeKey] && !light.defaultOn && light.changed,
                "the native settings model exposes a default-off Light mode switch");
        [root adopt:root.sections];
        require(root.sections.count == 3 && root.adoptions == 2, "re-adopting existing rows does not duplicate the sections");
        [root adopt:@[existing]];
        require(root.sections.count == 3 && root.adoptions == 3, "a rebuild regenerates the add-on sections once");
        SGModPage *unrelatedPage = [SGModPage new];
        unrelatedPage.title = @"Player";
        [unrelatedPage adopt:@[existing]];
        require(unrelatedPage.sections.count == 1, "other settings pages stay unchanged");
        SGRPlayerAnimatedView *cover = [SGRPlayerAnimatedView new];
        cover.playing = YES;
        SGRPlayerAnimatedView *pausedCover = [SGRPlayerAnimatedView new];
        pausedCover.playing = NO;
        light.changed(YES);
        SGTestAnimatedCoverModel *unrelatedCover = [SGTestAnimatedCoverModel new];
        unrelatedCover.playing = YES;
        require(unrelatedCover.playing, "cover hooks do not replace inherited superclass implementations globally");
        require([NSUserDefaults.standardUserDefaults boolForKey:light.key], "the UI callback persists Light mode");
        require(warpLink.isPaused && visualizerLink.isPaused && !reentrant.link.isPaused,
                "Light mode suspends GPU work while leaving lyrics live");
        NSInteger calls = reentrant.calls;
        [reentrant.link fire];
        require(reentrant.calls == calls + 1, "lyrics keep receiving their original callbacks in Light mode");
        require(!cover.playing && !pausedCover.playing, "existing animated covers pause immediately");
        [cover showClip:@"new track"];
        require(!cover.clipPlaying && [cover.lastClip isEqual:@"new track"], "new artwork still loads with its video paused");
        cover.playing = YES;
        require(!cover.playing, "a new playback request cannot restart animated artwork in Light mode");
        CADisplayLink *lightGpu = [CADisplayLink displayLinkWithTarget:warp selector:@selector(tick:)];
        lightGpu.paused = NO;
        require(lightGpu.isPaused, "new GPU links and owner resumes respect Light mode");
        notify(@"spotifyglass.playerTransition");
        notify(@"spotifyglass.playerTransitionEnded");
        require(warpLink.isPaused && lightGpu.isPaused, "transition completion does not override Light mode");
        light.changed(NO);
        require(!warpLink.isPaused && !lightGpu.isPaused && visualizerLink.isPaused,
                "turning Light mode off restores the latest GPU owner states");
        require(cover.playing && !pausedCover.playing, "only covers requesting playback resume");
        require(!untouched.isPaused, "unrelated display links remain unchanged by Light mode");
        SGSetLightMode(YES);
        cover.playing = NO;
        visualizerLink.paused = NO;
        SGSetLightMode(NO);
        require(!cover.playing && !visualizerLink.isPaused, "owner changes made while Light mode is on are preserved");
        SGSetLightMode(YES);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGPerformanceLightModeKey];
        notify(NSUserDefaultsDidChangeNotification);
        require(!warpLink.isPaused, "reset/import changes refresh Light mode without restarting");
        notify(UIApplicationWillResignActiveNotification);
        cover.playing = YES;
        SGSetLightMode(YES);
        SGSetLightMode(NO);
        require(!cover.playing && warpLink.isPaused, "disabling Light mode cannot restart visual work while inactive");
        notify(UIApplicationDidBecomeActiveNotification);
        require(cover.playing && !warpLink.isPaused, "visual owner requests resume on activation");
        __weak SGRPlayerAnimatedView *releasedCover;
        @autoreleasepool {
            SGRPlayerAnimatedView *temporaryCover = [SGRPlayerAnimatedView new];
            releasedCover = temporaryCover;
            [temporaryCover didMoveToWindow];
        }
        require(releasedCover == nil, "the animated cover registry holds no views strongly");
        puts("PASS: lifecycle, transition suspension, settings integration, live/persistent Light mode, animated covers, owner state and lyrics");
    }
    return 0;
}
