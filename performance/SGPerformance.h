#import <Foundation/Foundation.h>

// Installs once, only when the pinned 0.51.0 lyrics class has the verified callback signature.
void SGInstallPerformance(void);

extern NSString *const SGPerformanceLightModeKey;
void SGSetLightMode(BOOL on);
extern NSString *const SGPerformanceAutomaticLightModeKey;
void SGSetAutomaticLightMode(BOOL on);
NSString *SGPerformanceLightModeStatus(void);
