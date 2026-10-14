#import "SGPerfSettings.h"
#import "SGPerformance.h"
#import "SGPerfABI.h"

// Runtime interfaces verified in the official 0.51.0 binary. No older App/ source is linked.
@protocol SGPerfSettingsRow <NSObject>
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic) BOOL defaultOn;
@property (nonatomic, copy) void (^changed)(BOOL on);
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

static void adoptSections(id<SGPerfSettingsPage> page, SEL cmd, NSArray *sections) {
    // The real root builder uses title "Chroma". Its rebuild path calls adopt: too.
    if (!NSThread.isMainThread || ![page.title isEqualToString:@"Chroma"] ||
        ![sections isKindOfClass:NSArray.class]) {
        sg_adopt(page, cmd, sections);
        return;
    }
    for (id<SGPerfSettingsSection> section in sections) {
        if (![section isKindOfClass:sg_sectionClass] || ![section.rows isKindOfClass:NSArray.class]) {
            sg_adopt(page, cmd, sections);
            return;
        }
        for (id<SGPerfSettingsRow> row in section.rows) {
            if ([row isKindOfClass:sg_rowClass] && [row.key isEqualToString:SGPerformanceLightModeKey]) {
                sg_adopt(page, cmd, sections);
                return;
            }
        }
    }
    id<SGPerfSettingsRow> row = [sg_rowClass new];
    row.title = @"Light mode";
    row.subtitle = @"Keep backgrounds still and pause animated covers";
    row.key = SGPerformanceLightModeKey;
    row.defaultOn = NO;
    row.symbol = @"leaf";
    row.changed = ^(BOOL on) { SGSetLightMode(on); };
    id<SGPerfSettingsSection> section = [sg_sectionClass new];
    section.title = @"Performance";
    section.rows = @[row];
    section.footer = @"Applies immediately. Music controls and synchronized lyrics stay available.";
    sg_adopt(page, cmd, [sections arrayByAddingObject:section]);
}

void SGInstallPerformanceSettings(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class pageClass = NSClassFromString(@"SGModPage");
        sg_rowClass = NSClassFromString(@"SGModRow");
        sg_sectionClass = NSClassFromString(@"SGModSection");
        if (!SGPerfHasMethod(pageClass, @selector(adopt:), 'v', "@") ||
            !SGPerfHasMethod(pageClass, @selector(title), '@', "")) return;
        for (NSString *name in @[@"setTitle:", @"setSubtitle:", @"setKey:", @"setSymbol:", @"setChanged:"])
            if (!SGPerfHasMethod(sg_rowClass, NSSelectorFromString(name), 'v', "@")) return;
        if (!SGPerfHasMethod(sg_rowClass, @selector(setDefaultOn:), 'v', "B") ||
            !SGPerfHasMethod(sg_rowClass, @selector(key), '@', "")) return;
        for (NSString *name in @[@"setTitle:", @"setFooter:", @"setRows:"])
            if (!SGPerfHasMethod(sg_sectionClass, NSSelectorFromString(name), 'v', "@")) return;
        if (!SGPerfHasMethod(sg_sectionClass, @selector(rows), '@', "")) return;
        Method adopt = class_getInstanceMethod(pageClass, NSSelectorFromString(@"adopt:"));
        sg_adopt = (void (*)(id, SEL, NSArray *))method_getImplementation(adopt);
        method_setImplementation(adopt, (IMP)adoptSections);
    });
}
