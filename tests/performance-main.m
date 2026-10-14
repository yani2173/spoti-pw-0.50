#import "PerformanceUIKitStubs.h"
#import "../performance/SGPerformance.h"
#import <objc/message.h>

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
+ (instancetype)displayLinkWithTarget:(id)target selector:(SEL)selector {
    CADisplayLink *link = [self new];
    link->_target = target;
    link->_selector = selector;
    return link;
}
- (id)target { return _target; }
- (BOOL)invalidated { return _invalidated; }
- (void)invalidate { _invalidated = YES; _target = nil; }
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
int main(void) {
    @autoreleasepool {
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
        OtherTarget *other = [OtherTarget new];
        CADisplayLink *untouched = [CADisplayLink displayLinkWithTarget:other selector:@selector(tick)];
        require(untouched.target == other, "other targets retain Apple's original behavior");
        __weak SGRKaraokeView *released = view;
        view = nil;
        require(released == nil, "the original lyrics view can release while links exist");
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
        puts("PASS: weak ownership, inactive suspension, late links, resume, owner pause changes, original callbacks and frame rates");
    }
    return 0;
}
