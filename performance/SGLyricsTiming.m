#import "SGLyricsTiming.h"
#import "SGLyricsIndex.h"
#import "SGPerfABI.h"
#include <math.h>

@interface SGPerfTimingIndex : NSObject
@property(nonatomic) SGTimeIndex *index;
@property(nonatomic) const SGTimeSpan *source;
@property(nonatomic) NSUInteger count;
@end
@implementation SGPerfTimingIndex
- (void)dealloc { SGTimeIndexDestroy(_index); }
@end

static char timingKey;
static ptrdiff_t spansOffset, breaksOffset, breakCountOffset;
static Ivar keptIvar;
static NSUInteger (*originalQuery)(id, SEL, double, int64_t *, int64_t *, int64_t *);
static void (*originalRebuild)(id, SEL);

static void timeLines(id view, SEL cmd) {
    // Clear before the core frees/reallocates its buffers, even when malloc reuses
    // the address or a new song has the same line count as the previous song.
    objc_setAssociatedObject(view, &timingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    originalRebuild(view, cmd);
}

static NSUInteger sungAt(id view, SEL cmd, double time, int64_t *active, int64_t *focus, int64_t *openBreak) {
    if (!NSThread.isMainThread || !isfinite(time)) return originalQuery(view, cmd, time, active, focus, openBreak);
    const char *bytes = (__bridge const void *)view;
    id kept = object_getIvar(view, keptIvar);
    if (![kept isKindOfClass:NSArray.class]) return originalQuery(view, cmd, time, active, focus, openBreak);
    NSUInteger count = [kept count];
    if (count < 32 || count > 16384) return originalQuery(view, cmd, time, active, focus, openBreak);
    const SGTimeSpan *spans;
    const SGTimeBreak *breaks;
    NSUInteger breakCount;
    memcpy(&spans, bytes + spansOffset, sizeof(spans));
    memcpy(&breaks, bytes + breaksOffset, sizeof(breaks));
    memcpy(&breakCount, bytes + breakCountOffset, sizeof(breakCount));
    if (!spans || breakCount > count + 1 || (breakCount && !breaks))
        return originalQuery(view, cmd, time, active, focus, openBreak);
    SGPerfTimingIndex *state = objc_getAssociatedObject(view, &timingKey);
    if (!state || state.source != spans || state.count != count) {
        state = [SGPerfTimingIndex new];
        state.source = spans;
        state.count = count;
        state.index = SGTimeIndexCreate(spans, count);
        objc_setAssociatedObject(view, &timingKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    size_t result;
    if (!SGTimeIndexQuery(state.index, time, breaks, breakCount, active, &result, focus, openBreak))
        return originalQuery(view, cmd, time, active, focus, openBreak);
    return result;
}

void SGInstallLyricsTiming(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"SGRKaraokeView");
        SEL query = sel_registerName("sungAt:into:focus:openBreak:");
        if (!SGPerfHasMethod(cls, query, 'Q', "d^^^") ||
            !SGPerfHasMethod(cls, sel_registerName("timeLines"), 'v', "")) return;
        Method method = class_getInstanceMethod(cls, query);
        for (unsigned int i = 3; i < 6; i++) {
            char type[32] = {0};
            method_getArgumentType(method, i, type, sizeof(type));
            if (strcmp(type, "^q")) return;
        }
        const char *names[] = {"_spans", "_kept", "_breaks", "_breakCount"};
        const char *types[] = {"^{?=qq}", "@\"NSArray\"", "^{?=qqq}", "Q"};
        ptrdiff_t ignored;
        ptrdiff_t *offsets[] = {&spansOffset, &ignored, &breaksOffset, &breakCountOffset};
        for (unsigned int i = 0; i < 4; i++) {
            Ivar ivar = class_getInstanceVariable(cls, names[i]);
            if (!ivar || strcmp(ivar_getTypeEncoding(ivar), types[i])) return;
            *offsets[i] = ivar_getOffset(ivar);
        }
        keptIvar = class_getInstanceVariable(cls, "_kept");
        originalQuery = (void *)method_getImplementation(method);
        originalRebuild = (void *)method_getImplementation(class_getInstanceMethod(cls, sel_registerName("timeLines")));
        SGPerfReplaceMethod(cls, query, (IMP)sungAt);
        SGPerfReplaceMethod(cls, sel_registerName("timeLines"), (IMP)timeLines);
    });
}
