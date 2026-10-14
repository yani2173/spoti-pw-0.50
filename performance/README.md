# Performance add-on for the actual 0.50.0 release

The build uses the original official kit, verified by the published SHA-256:
`da81a22bbdb4a27a060bead23eb3ff0aa90a06e4f22cd44927f7f9bff161839f`.
`SGPerformance050.dylib` is injected alongside it. The build compares every Mach-O code/data section
of the final `spotifyglass.dylib` with the original kit after signing; a difference fails the build.
This preserves the original 0.50.0 core, rather than labelling the public 0.22.0 source as 0.50.0.

The add-on only wraps `SGRKaraokeView`'s `tick` display links. A weak target breaks the view/link
retention cycle. WillResignActive pauses these links immediately and keeps a newly created link
paused during the interval in which UIApplication still reports Active. DidBecomeActive restores
the pause state requested by the owner, including requests made while inactive. Other display link
targets, callbacks, timestamps, and the original 80–120 Hz range are kept as they are.

The class, callback, and argument passing were verified against the actual release binary:

- `SGRKaraokeView.startLink` at `0x8be6c`, signature `v16@0:8`.
- `0x8be80`: `mov x19, x0` saves the view (`self`).
- `0x8beec`: `mov x2, x19` passes that view as the factory's target.
- The factory stub at `0x1d0800` resolves to `displayLinkWithTarget:selector:`.
- The callback selector reference at `0x3872e0` resolves to `tick`.
- `0x8befc` stores the returned link in the view's `_link` ivar.

Runtime installation checks the class and zero-argument void callback before installing, and does
nothing when the expected ABI is absent. Its scope is the lyrics display-link lifecycle;
refactoring the unavailable newer source still requires that source.

The macOS test builds the actual implementation against UIKit stand-ins to check ownership,
callbacks, background suspension, late links, resuming, preserving owner pauses, other targets,
and frame rates. CI also compiles the iOS dylib. Device frame pacing, memory, and battery use still
need testing on a real decrypted Spotify 9.1.78 IPA and an iPhone; no measured speedup is claimed.
