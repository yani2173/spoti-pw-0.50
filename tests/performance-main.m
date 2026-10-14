#import "PerformanceUIKitStubs.h"
#import "../performance/SGPerformance.h"
#import <objc/message.h>

static void require(BOOL condition, const char *message);
static BOOL nilFactory;
NSNotificationName const UIApplicationWillResignActiveNotification = @"UIApplicationWillResignActiveNotification";
NSNotificationName const UIApplicationDidBecomeActiveNotification = @"UIApplicationDidBecomeActiveNotification";
@implementation UIApplication
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
static void require(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static void notify(NSNotificationName name) {
    [NSNotificationCenter.defaultCenter postNotificationName:name object:nil];
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1) {
            UIApplication.sharedApplication.applicationState = strcmp(argv[1], "background") == 0
                ? UIApplicationStateBackground : UIApplicationStateInactive;
            SGInstallPerformance();
            SGRKaraokeView *view = [SGRKaraokeView new];
            CADisplayLink *link = [CADisplayLink displayLinkWithTarget:view selector:@selector(tick)];
            require(link.isPaused, "installation while inactive immediately suspends new links");
            link.paused = NO;
            require(link.isPaused, "owner resume cannot bypass an initially inactive app");
            UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
            notify(UIApplicationDidBecomeActiveNotification);
            require(!link.isPaused, "the initially inactive link resumes on activation");
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
        puts("PASS: ownership, immediate cleanup, off-main release, inactive suspension, nested notifications, callbacks and frame rates");
    }
    return 0;
}
