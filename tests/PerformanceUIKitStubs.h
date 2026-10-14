#import <Foundation/Foundation.h>

// Recent macOS versions also have CADisplayLink. Give the stand-in a distinct runtime class name.
#define CADisplayLink SGTestDisplayLink

typedef NS_ENUM(NSInteger, UIApplicationState) {
    UIApplicationStateActive, UIApplicationStateInactive, UIApplicationStateBackground
};
extern NSNotificationName const UIApplicationWillResignActiveNotification;
extern NSNotificationName const UIApplicationDidBecomeActiveNotification;
@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
@property (nonatomic) UIApplicationState applicationState;
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL success))completion;
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
