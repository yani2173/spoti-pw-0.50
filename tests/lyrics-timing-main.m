#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../performance/SGLyricsTiming.h"
#import "../performance/SGLyricsIndex.h"
#include <stdlib.h>
#include <stdio.h>

static void check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
@interface SGTestTimingModel : NSObject {
    SGTimeSpan *_spans;
    NSArray *_kept;
    SGTimeBreak *_breaks;
    NSUInteger _breakCount;
}
@property(nonatomic) NSInteger nativeQueries, builds;
@property(nonatomic, copy) NSArray *nextRows;
- (void)timeLines;
- (NSUInteger)sungAt:(double)time into:(int64_t *)active focus:(int64_t *)focus openBreak:(int64_t *)opened;
@end
@implementation SGTestTimingModel
- (instancetype)init {
    if ((self = [super init])) {
        _spans = calloc(2048, sizeof(*_spans));
        _breaks = calloc(2048, sizeof(*_breaks));
    }
    return self;
}
- (void)dealloc { free(_spans); free(_breaks); }
- (void)timeLines {
    self.builds++;
    // Deliberately reuse the same memory and row count on subsequent tracks.
    _kept = self.nextRows;
    _breakCount = 0;
    for (NSUInteger i = 0; i < _kept.count; i++) {
        _spans[i].start = [_kept[i][0] longLongValue];
        _spans[i].end = [_kept[i][1] longLongValue];
    }
}
- (NSUInteger)sungAt:(double)time into:(int64_t *)active focus:(int64_t *)focus openBreak:(int64_t *)opened {
    (void)time;
    self.nativeQueries++;
    active[0] = 999; *focus = 999; *opened = -1;
    return 1; // Distinct fallback marker; semantic parity is checked against ARM64 in Python.
}
@end
@interface SGRKaraokeView : SGTestTimingModel
@end
@implementation SGRKaraokeView
@end
static NSArray *rows(NSUInteger count, int64_t origin) {
    NSMutableArray *array = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) [array addObject:@[@(origin + (int64_t)i * 1000), @(origin + (int64_t)i * 1000 + 800)]];
    return array;
}
static NSUInteger query(SGTestTimingModel *view, double time, int64_t *focus) {
    int64_t active[6], opened;
    return [view sungAt:time into:active focus:focus openBreak:&opened];
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc > 1 && [@(argv[1]) isEqual:@"unsupported"]) {
            SEL selector = @selector(sungAt:into:focus:openBreak:);
            Method method = class_getInstanceMethod(SGRKaraokeView.class, selector);
            class_addMethod(SGRKaraokeView.class, selector, method_getImplementation(method), "Q48@0:8d16^i24^q32^q40");
            SGInstallLyricsTiming();
            SGRKaraokeView *view = [SGRKaraokeView new];
            view.nextRows = rows(100, 0); [view timeLines];
            int64_t focus;
            query(view, 500, &focus);
            check(focus == 999 && view.nativeQueries == 1, "unsupported output-pointer ABI is untouched");
            puts("PASS: unsupported timing ABI");
            return 0;
        }
        SGInstallLyricsTiming(); SGInstallLyricsTiming();
        SGRKaraokeView *view = [SGRKaraokeView new];
        view.nextRows = rows(100, 0); [view timeLines];
        int64_t focus;
        for (int i = 0; i < 1000; i++) {
            query(view, 500, &focus);
            check(focus == 0, "stable indexed results across display ticks");
        }
        check(view.nativeQueries == 0, "long lyrics use the index rather than the original full scan");
        query(view, 99000, &focus); check(focus == 99, "late song lookup");
        query(view, 1500, &focus); check(focus == 1, "seeking backward uses current time");
        view.nextRows = rows(100, 100000); [view timeLines];
        check(query(view, 500, &focus) == 0 && focus == -1, "same-address same-count rebuild invalidates old starts and ends");
        query(view, 101500, &focus); check(focus == 1, "new track lookup uses rebuilt buffers");
        view.nextRows = rows(20, 0); [view timeLines];
        query(view, 500, &focus);
        check(view.nativeQueries == 1 && focus == 999, "short lyrics retain the original implementation");
        NSMutableArray *unordered = [rows(100, 0) mutableCopy];
        [unordered exchangeObjectAtIndex:0 withObjectAtIndex:99];
        view.nextRows = unordered; [view timeLines];
        query(view, 500, &focus); query(view, 700, &focus);
        check(view.nativeQueries == 3, "unordered data falls back without rebuilding its index on every tick");
        view.nextRows = rows(100, 0); [view timeLines];
        query(view, 500, &focus);
        check(focus == 0 && view.nativeQueries == 3, "a supported rebuild can recover from the fallback");
        __block int64_t workerFocus;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            query(view, 500, &workerFocus);
            dispatch_semaphore_signal(done);
        });
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        check(workerFocus == 999 && view.nativeQueries == 4, "off-main queries pass through");
        SGTestTimingModel *other = [SGTestTimingModel new];
        other.nextRows = rows(100, 0); [other timeLines];
        query(other, 500, &focus);
        check(focus == 999 && other.nativeQueries == 1, "inherited methods are overridden only on the mod class");
        __weak SGRKaraokeView *released;
        @autoreleasepool {
            SGRKaraokeView *temporary = [SGRKaraokeView new];
            temporary.nextRows = rows(100, 0); [temporary timeLines];
            query(temporary, 500, &focus); released = temporary;
        }
        check(!released, "the index does not retain its view");
        puts("PASS: timing cache lifecycle, same-address rebuilds, seeks, fallback, ABI and weak ownership");
    }
    return 0;
}
