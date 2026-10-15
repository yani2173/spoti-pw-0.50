#import <Foundation/Foundation.h>

// Main-thread policy for verified 0.51.0 decorative renderers, separate from audio playback.
// interactionBusy covers player transitions OR UIKit scroll/drag tracking.
void SGInstallLightRendering(BOOL lightMode, BOOL inactive, BOOL interactionBusy);
void SGApplyLightRendering(BOOL lightMode, BOOL inactive, BOOL interactionBusy);
