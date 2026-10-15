#import <Foundation/Foundation.h>

// Main-thread policy for verified 0.51.0 decorative renderers, separate from audio playback.
void SGInstallLightRendering(BOOL lightMode, BOOL inactive, BOOL transitioning);
void SGApplyLightRendering(BOOL lightMode, BOOL inactive, BOOL transitioning);
