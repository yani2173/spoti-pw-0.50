#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, UIApplicationState) {
    UIApplicationStateActive, UIApplicationStateInactive, UIApplicationStateBackground
};
extern NSNotificationName const UIApplicationWillResignActiveNotification;
extern NSNotificationName const UIApplicationDidBecomeActiveNotification;
@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
@property (nonatomic) UIApplicationState applicationState;
@end
@interface CADisplayLink : NSObject
+ (instancetype)displayLinkWithTarget:(id)target selector:(SEL)selector;
@property (nonatomic, getter=isPaused) BOOL paused;
@property (nonatomic) NSInteger preferredFramesPerSecond;
@property (nonatomic, copy) void (^pauseObserver)(BOOL paused);
@property (nonatomic, readonly) id target;
@property (nonatomic, readonly) BOOL invalidated;
- (void)invalidate;
- (void)fire;
@end
