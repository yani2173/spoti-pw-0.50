# Performance add-on for the actual 0.51.0 release

The build uses the original official kit, verified by the published SHA-256:
`21587c2b9433e3482c8c0ca6c6e4c7325a4b2c76d69bed607dfb031791231bd8`.
`SGPerformance051.dylib` is injected alongside it. After signing, the builder compares every
Mach-O code/data section of `spotifyglass.dylib` with the original kit and fails on a difference.
The kit supports Spotify 9.1.90 and 9.1.78. Its tag still points to public source version 0.22.0;
the builder uses the actual compiled 0.51.0 release instead of relabelling the older source.

## Preserved lifecycle fixes

The add-on wraps `SGRKaraokeView`'s zero-argument `tick` display links with weak view targets.
A view-owned sentinel holds links weakly and invalidates them on the main thread when the view
is released, including paused links which would never get another cleanup tick. Inactive apps
suspend managed links immediately; background launches and late-created links are also covered.
Owner pause requests are preserved. State sweeps skip unchanged setters, handle nested
notifications, and discard older off-main notifications queued before newer main-thread events.

## Player transitions

The add-on also wraps the verified `SGRWarpTicker` and `SGVisualizerTicker` `tick:` callbacks.
These tickers already have weak layer/view owners; their original strong link-target ownership
is retained, and `invalidate` releases the proxy's ticker even if the link itself stays alive.
The original link, timestamps, and callback arguments are forwarded unchanged.

The mod's existing `spotifyglass.playerTransition` and `spotifyglass.playerTransitionEnded`
notifications suspend lyrics, moving-background and visualizer links until the player's transition
coordinator completes, including cancelled swipes. This avoids their per-frame work competing
with the player's animation. Links created or resumed by their owners mid-transition stay paused.
An end event cannot resume an inactive app or a link paused by its owner. Normal frame rates are
unchanged; there is no app-wide FPS cap or feature/access change.

The suspension follows completion rather than the nominal animation duration: an interactive
drag can outlast that duration. A ten-second generation-checked recovery protects against a missing
end event, and app deactivation clears an interrupted transition. Other display-link targets pass
through Apple's original implementation. Runtime signature guards skip unsupported GPU tickers.

## Verified ABI in the original 0.51.0 binary

- `SGRKaraokeView.startLink`: `0xca5c8`; `0xca648` passes self as factory target; callback
  selector reference `0x5094a0` resolves to `tick`; `0xca658` stores the link in `_link`.
- `SGRWarpLayer.updateLink`: `0xb1650`; it creates a transient `SGRWarpTicker`, gives it a weak
  layer, then `0xb16ac` passes it as target. The link is its only persistent strong owner.
- `SGVisualizerView.updateLink`: `0x2ed0e0`; `0x2ed2d0` loads its ticker into the target argument.
- Factory stub `0x3181e0` uses selector reference `0x5049c8`, which resolves to
  `displayLinkWithTarget:selector:`. GPU callback reference `0x5094a8` resolves to `tick:`.
- `SGRWarpTicker.tick:` (`0xb0474`) and `SGVisualizerTicker.tick:` (`0x2ec694`) have signature
  `v24@0:8@16`. Their owner properties have the `W` (weak) attribute in the binary's metadata.
- Both transition notification strings exist in the original release.

## Light mode

The optimized build adds **Mod Settings → Performance → Light mode** to the original root settings
page. It uses the existing `SGModRow`/`SGModSection` model and the root's `SGModPage.adopt:` path,
so both initial creation and dynamic rebuilds include exactly one switch. Existing sections remain
in place. Other settings pages are unchanged, and unsupported settings signatures skip installation.

The key is `spotifyglass.performance.lightMode`, default off, in the app's standard defaults.
Its native row writes the preference and invokes the changed callback; the add-on applies it
immediately. The saved value is read at installation. Default changes also refresh it, including
reset/import, and the key uses the prefix already covered by the mod's settings backup/reset.

While on, the mode suspends the verified moving-background and visualizer display links. Lyrics
continue with their original timing and frame-rate settings. GPU links created or resumed while
the mode is active stay paused. Owner pause requests and transition/inactive suspension still win
when it is turned off. Background colors and artwork updates can still draw their static contents;
the mode is scoped to continuous decorative animation, rather than all UIKit animations.

Animated player covers use a separate weak view registry. `SGRPlayerAnimatedView.setPlaying:` at
`0xfe538` has signature `v20@0:8B16` and updates its clips. `_playing` is a one-byte BOOL at offset
40 in this release. Its `showClip:` (`0xfdd90`) reads that flag at `0xfde88` before setting the new
clip's playback, so the add-on clamps it before a new clip is shown. `didMoveToWindow` (`0xfd6ac`)
also registers views. Requested playback is kept separately and restored when allowed; owner-paused
covers stay paused and inactive apps cannot restart them. The class/ivar/method signatures and KVC
ivar access are checked before hooking. Nothing in the audio playback engine is changed.

The settings ABI evidence is `SGModPage.adopt:` (`0x15b4e8`, `v24@0:8@16`), invoked after the
title is set by `initWithTitle:intro:sections:footer:` (`0x15b314`). `initWithTitle:build:` and
`rebuild` use the same adoption path. The root builder (`0x3e880`) supplies CFString `0x4ac758`,
whose value is `Chroma`. Row and section accessor signatures were verified in the same binary.
No source from the older release is linked into the add-on.

## Automatic Light mode

The Performance section also offers **Automatic Light mode**, default off, stored separately under
`spotifyglass.performance.automaticLightMode`. The effective mode is the manual request OR an
enabled automatic request while Low Power Mode is on or the thermal reduction is latched.
Automatic activation never rewrites the manual preference. Disabling automatic mode leaves manual
Light mode intact; resetting/importing the settings updates both preferences live.

The policy reads public `NSProcessInfo.lowPowerModeEnabled` and `thermalState` values. Serious or
Critical pressure latches the thermal reduction; it stays latched through Fair and clears at Nominal.
Starting at Fair does not trigger a new reduction. This avoids cycling effects repeatedly during
cooling. Ending one trigger cannot override another trigger, an owner pause, an inactive app or a
manual request. GPU/cover behavior and the unchanged lyrics path use the same effective mode as before.

Power, thermal and relevant preference notifications refresh conditions on the main thread. Queued
notifications read current conditions rather than capturing stale values. Foreground activation also
refreshes conditions before visual work resumes, covering changes missed during suspension. Unrelated
defaults notifications skip policy updates. There is no per-frame or background polling timer.
The native settings page displays a **Status** value from cached state while it is open: Normal,
Light · Manual, Light · Low Power, Light · Heat, or Light · Cooling.

## Packaging and validation

IPA preparation checks the main executable's encryption commands in every arm64 slice, including
universal files. Final verification requires the original dylibs and the add-on to be loaded, with
the add-on after the original core. A copied but unloaded add-on fails verification. Existing
0.50.0/0.51.0 performance injections are rejected; these checks do not decrypt an IPA.

The macOS tests compile the actual implementation against UIKit stand-ins and cover weak view
ownership, paused-link cleanup, off-main release, inactive/background launches, nested and queued
notifications, owner pauses, transition suspension, late GPU links, callback forwarding, GPU ticker
ownership, invalidation, unsupported signatures, and preserved frame rates. CI compiles the arm64
iOS dylib. Light mode tests cover native settings integration, rebuild deduplication, defaults,
startup restoration, live switching, paused/new GPU links, lyrics, animated cover requests,
new clips, inactive restoration, reset, weak view ownership and unsupported settings/cover ABIs.
Automatic-mode checks cover opt-in defaults, live and saved startup behavior, Low Power Mode,
Serious/Critical pressure, cooling hysteresis, Fair startup, overlapping triggers, manual priority,
status changes, owner pauses, missed foreground conditions, off-main/stale notifications and reset.
Real-kit packaging is tested with synthetic executables. Actual Spotify frame pacing,
memory and battery use still require testing on an iPhone; no measured device speedup is claimed.

## Guarded 0.51.0 lyrics repairs

`SGLyricsRepair.m` repairs three paths verified in the compiled official core. Its installer
requires arm64 Mach-O UUID `2A5B5C1F-DAEA-35BE-BA16-8661A6C6F24E`, the expected segment layout,
instruction fingerprints, original selector references, and compatible public method signatures.
An unsupported image is left alone. This is independent of Light mode and Plus access.

- The JSON lyrics parser at `0x2579e8` enumerates `lines` and converts `startTimeMs` without
  checking their types. Only its JSON decode result is sanitized: non-array collections become
  empty, and rows with explicit null/object/array timestamps are skipped. Valid content, missing
  timestamps and existing string/number conversion semantics are preserved. Other JSON consumers,
  decoding options and errors pass through unchanged.
- The same parser's first-byte format check at `0x257a34` misclassifies whitespace-prefixed JSON
  as protobuf. Only that single-byte read receives a pointer after JSON whitespace when followed
  by `{`. Full data reads and protobuf input retain their original pointer and length.
- The lock-screen lyrics restore branch publishes its cached metadata at `0x24fcc0` without
  updating progress. It now uses the original elapsed-time helper at `0x24ff38`, which accounts
  for the player's clock, seeks and playback rate. The matching cached timestamp is read under
  the original lock. A changed snapshot, invalid clock or unsupported caller passes through;
  all metadata fields except elapsed time are retained. This does not seek the audio player.

The add-on adds unique forwarding selectors and rebinds three aligned pointers in the original
image's writable `__DATA.__objc_selrefs`: `bytes` at `0x5040a8`,
`JSONObjectWithData:options:error:` at `0x5038a0`, and `setNowPlayingInfo:` at `0x507d30`.
The forwarding functions check return addresses `0x257a34`, `0x257a58`, and `0x24fcc4` respectively.
Existing Foundation/MediaPlayer implementations are not replaced. Other callers, including
Spotify and the core's ordinary lyric updates, retain their original behavior. No executable
instructions or packaged core sections are changed. Original lock/cache/timestamp globals are
`0x53fca8`, `0x53fcc8`, and `0x53fce8`; the elapsed helper ABI is
`double (id metadata, double reportedAt, double now)` using `CFAbsoluteTimeGetCurrent()`.

The additional macOS tests use real Foundation decoding and an image fixture from the actual kit,
with simulated selector relocation and a stand-in metadata center/player clock. They cover malformed
provider values, valid/whitespace/protobuf inputs, forwarding, errors, version/instruction guards,
clock changes and immutable metadata. CI also builds the iOS code and verifies packaged core sections.
These are not end-to-end tests of the iOS core or lock-screen UI; check lyrics loading and disabling
lock-screen lyrics during playback on a device after installing the optimized build.
