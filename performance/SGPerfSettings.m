#import "SGPerfSettings.h"
#import "SGPerformance.h"
#import "SGPerfABI.h"
#ifdef SG_PERFORMANCE_TEST
#import "../tests/PerformanceUIKitStubs.h"
#else
#import <UIKit/UIKit.h>
#endif

// Runtime interfaces verified in the official 0.51.0 binary. No older App/ source is linked.
@protocol SGPerfSettingsRow <NSObject>
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic) BOOL defaultOn;
@property (nonatomic, copy) void (^changed)(BOOL on);
@property (nonatomic, copy) void (^action)(void);
@property (nonatomic, copy) NSString *(^value)(void);
@end

@protocol SGPerfSettingsSection <NSObject>
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, copy) NSArray *rows;
@end

@protocol SGPerfSettingsPage <NSObject>
@property (nonatomic, readonly) NSString *title;
- (void)adopt:(NSArray *)sections;
@end

static Class sg_rowClass, sg_sectionClass;
static void (*sg_adopt)(id, SEL, NSArray *);
static char sg_creditKey;

static void adoptSections(id<SGPerfSettingsPage> page, SEL cmd, NSArray *sections) {
    // The real root builder uses title "Chroma". Its rebuild path calls adopt: too.
    if (!NSThread.isMainThread || ![page.title isEqualToString:@"Chroma"] ||
        ![sections isKindOfClass:NSArray.class]) {
        sg_adopt(page, cmd, sections);
        return;
    }
    BOOL hasLightMode = NO, hasCredit = NO;
    for (id<SGPerfSettingsSection> section in sections) {
        if (![section isKindOfClass:sg_sectionClass] || ![section.rows isKindOfClass:NSArray.class]) {
            sg_adopt(page, cmd, sections);
            return;
        }
        for (id<SGPerfSettingsRow> row in section.rows) {
            if ([row isKindOfClass:sg_rowClass] && [row.key isEqualToString:SGPerformanceLightModeKey]) {
                hasLightMode = YES;
            }
            if (objc_getAssociatedObject(row, &sg_creditKey)) hasCredit = YES;
        }
    }
    if (hasLightMode && hasCredit) {
        sg_adopt(page, cmd, sections);
        return;
    }
    NSMutableArray *augmented = [sections mutableCopy];
    if (!hasLightMode) {
        id<SGPerfSettingsRow> row = [sg_rowClass new];
        row.title = @"Light mode";
        row.subtitle = @"Stop visualizer processing, pause animated covers and reduce transitions";
        row.key = SGPerformanceLightModeKey;
        row.defaultOn = NO;
        row.symbol = @"leaf";
        row.changed = ^(BOOL on) { SGSetLightMode(on); };
        id<SGPerfSettingsRow> automatic = [sg_rowClass new];
        automatic.title = @"Automatic Light mode";
        automatic.subtitle = @"Use Light mode for Low Power Mode or high temperature";
        automatic.key = SGPerformanceAutomaticLightModeKey;
        automatic.defaultOn = NO;
        automatic.symbol = @"sparkles";
        automatic.changed = ^(BOOL on) { SGSetAutomaticLightMode(on); };
        id<SGPerfSettingsRow> status = [sg_rowClass new];
        status.title = @"Status";
        status.value = ^NSString *{ return SGPerformanceLightModeStatus(); };
        id<SGPerfSettingsSection> section = [sg_sectionClass new];
        section.title = @"Performance";
        section.rows = @[row, automatic, status];
        section.footer = @"Manual Light mode stays on. Automatic mode restores effects after Low Power Mode ends and the phone cools down. Music controls and synchronized lyrics stay available.";
        [augmented addObject:section];
    }
    if (!hasCredit) {
        id<SGPerfSettingsRow> credit = [sg_rowClass new];
        credit.title = @"Modified by Yani";
        credit.subtitle = @"yaniminchev.eu";
        credit.symbol = @"globe";
        credit.action = ^{
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://yaniminchev.eu"]
                                              options:@{} completionHandler:nil];
        };
        objc_setAssociatedObject(credit, &sg_creditKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id<SGPerfSettingsSection> attribution = [sg_sectionClass new];
        attribution.rows = @[credit];
        [augmented addObject:attribution];
    }
    sg_adopt(page, cmd, augmented);
}

void SGInstallPerformanceSettings(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class pageClass = NSClassFromString(@"SGModPage");
        sg_rowClass = NSClassFromString(@"SGModRow");
        sg_sectionClass = NSClassFromString(@"SGModSection");
        if (!SGPerfHasMethod(pageClass, @selector(adopt:), 'v', "@") ||
            !SGPerfHasMethod(pageClass, @selector(title), '@', "")) return;
        for (NSString *name in @[@"setTitle:", @"setSubtitle:", @"setKey:", @"setSymbol:", @"setChanged:", @"setAction:", @"setValue:"])
            if (!SGPerfHasMethod(sg_rowClass, NSSelectorFromString(name), 'v', "@")) return;
        if (!SGPerfHasMethod(sg_rowClass, @selector(setDefaultOn:), 'v', "B") ||
            !SGPerfHasMethod(sg_rowClass, @selector(key), '@', "")) return;
        for (NSString *name in @[@"setTitle:", @"setFooter:", @"setRows:"])
            if (!SGPerfHasMethod(sg_sectionClass, NSSelectorFromString(name), 'v', "@")) return;
        if (!SGPerfHasMethod(sg_sectionClass, @selector(rows), '@', "")) return;
        Method adopt = class_getInstanceMethod(pageClass, NSSelectorFromString(@"adopt:"));
        sg_adopt = (void (*)(id, SEL, NSArray *))method_getImplementation(adopt);
        SGPerfReplaceMethod(pageClass, NSSelectorFromString(@"adopt:"), (IMP)adoptSections);
    });
}
