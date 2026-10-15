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
coordinator completes, including cancelled swipes. Visualizer input processing and animated player
covers also stop during that interval, in normal mode as well as Light mode. This avoids their per-frame work competing
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

While on, the mode suspends moving-background display links and uses the visualizer's original
stop path to shut down its processing and input work. Remaining verified GPU links stay paused.
Lyrics continue with their original timing and frame-rate settings. Owner pause requests and
transition/inactive suspension still win when it is turned off. Background colors and artwork
continue updating their static content, with the decorative transitions reduced as described below.

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
The lighter-rendering tests also exercise original visualizer stop/resume requests, input processing,
late views, startup, reentrant policy changes, access checks, retained static frames, generation-checked
clip readiness and scoped decorative transitions. Policy integration tests cover manual and automatic
activation/recovery, including heat hysteresis.
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


## Lighter rendering in Light mode

`SGLightRendering.m` takes the effective manual/automatic policy, app activity and transition state from
`SGPerformance.m` on the main thread. It keeps visualizer views weakly and retains each owner's
latest running request separately. It never overwrites the owner's preference or starts an
owner-stopped view when the policy changes. Repeated unchanged policy updates avoid new work.

The actual 0.51.0 `SGVisualizerView.setRunning:` (`0x2ecfec`, `v20@0:8B16`) writes `_running`
only when changed and calls `updateLink` (`0x2ed0e0`, `v16@0:8`). `running` is at `0x2f0534`,
`B16@0:8`. The add-on clamps that runtime request while Light mode, app inactivity or a player transition applies,
including creation/window/input updates through `updateLink`. It forwards the original method,
so the original availability, window, power and heat checks still decide whether work can run.
The original stop path invalidates the display link and updates its input consumers instead of
only pausing the add-on's display link. `updateInputs` (`0x2ee67c`) stops the visualizer's analysis
consumer when no link is present (`0x2ee6fc`) and sends `setPlaying:NO` to its video input
(`0x2ee798–0x2ee7a4`). That clip's setter (`0x2ddff8`) pauses its own AVPlayer. This affects
decorative visualizer inputs, not Spotify's audio playback or Sing's processing. Static renderer
content and the owner's latest request are retained; original processing is restored when allowed.

The following original decorative methods receive `animated:NO` in Light mode while retaining
all other arguments and updates:

- `SGRWarpLayer.setArtwork:animated:` (`0xb0930`, `v28@0:8@16B24`). Its `takePending`
  (`0xb0e14`, `v16@0:8`) also clamps the verified BOOL `_pendingAnimated`, so artwork conversion
  queued before activation cannot introduce a late fade. The original static draw path remains.
- `SGRPlayerAnimatedView.show:animated:` (`0xfd73c`, `v24@0:8B16B20`),
  `setColor:animated:` (`0xfdb50`, `v28@0:8@16B24`), `dimFrom:animated:`
  (`0xfdca8`, `v24@0:8f16B20`) and `setLyricsUp:animated:` (`0xfe634`, `v24@0:8B16B20`).
- `SGRPlayerVisualizerHost.show:animated:` (`0x1432e4`, `v24@0:8B16B20`) and
  `setLyricsUp:animated:` (`0x143668`, `v24@0:8B16B20`).

For a ready animated cover, `fadeIn:generation:` (`0xfe1b4`, `v32@0:8@16Q24`) checks the current
clip and `_generation` (verified unsigned 64-bit ivar) before starting its crossfade. In Light mode,
the add-on performs those same identity/generation checks, then calls the original `dropLeaving`
(`0xfe0b0`) before forwarding readiness. The core therefore displays the ready new clip without
crossfading old video layers; its cleanup stops their players and removes their layers. Stale ready
callbacks retain their original no-op behavior, and artwork is kept until its replacement is ready.

Hooks require the verified method and relevant ivar types. Inherited methods are overridden only on
these classes; other UIKit animations and unrelated superclass instances remain unchanged. Off-main
callbacks pass through. No new polling, per-frame scans, frame-rate limits or global animation policy
are introduced. Existing lyrics repairs, Light mode opt-in defaults and original Plus checks remain.
The regression tests use stand-in renderers; actual memory, battery and frame pacing need measurement
on a phone, and no numerical device-performance gain is claimed.


## Indexed lyric timing in normal and Light mode

The actual 0.51.0 `SGRKaraokeView.tick` calls `sungAt:into:focus:openBreak:` (`0xce558`,
`Q48@0:8d16^q24^q32^q40`) on display ticks. The original method scans line starts and then
line ends from the beginning of the song to select up to six active lines. Long lyrics therefore
repeat work even when only a small number of rows are on screen. Other original methods already
skip unchanged blur/fill/layout values; these guards are preserved.

`SGLyricsTiming.m` uses `SGLyricsIndex.c` for songs with 32–16384 ordered timing spans. An
upper-bound search finds the most recent started line; a maximum-end tree finds the first six
still-active rows without rescanning expired lyrics. Building is O(n) once per timing rebuild;
line selection is O(log n + k log n), k <= 6. Instrumental breaks retain their original ordered
scan and precedence. Exact end/start boundaries, duplicate starts, overlapping lines, backward
seeks, the latest-line fallback and the final 500 ms break rule preserve the original results.
No timing or frame-rate request is changed, and queries perform no allocation after initialization.

The hook requires verified method types and these non-fragile ivar encodings: `_kept` (`NSArray`),
`_spans` (`^{?=qq}`), `_breaks` (`^{?=qqq}`), and `_breakCount` (`Q`). `timeLines` (`0xcaf38`,
`v16@0:8`) frees/rebuilds those buffers; the add-on invalidates its index before that method runs,
including equal-sized songs whose allocations reuse an address. It also checks pointer/count changes.
The index belongs to the view, retains no view or source array, and uses at most 256 KiB of auxiliary
storage. Short/unordered/unusually large data, failed allocation, non-finite time, unsupported ABI
and off-main queries use the original method. An unsupported/failed index is not rebuilt per frame.

The differential tests execute the **original arm64 method** from the checksum-pinned 0.51.0 kit
under Unicorn 2.1.4, replacing only its `NSArray.count` message. They compare the compiled C index
with thousands of original results for randomized overlaps, breaks, boundaries, large integers,
duplicate starts and backward seeks. Additional macOS runtime tests cover hook installation,
cache invalidation with buffer reuse, fallback paths and view lifetime. This tests timing selection,
not iOS rendering, device FPS or Spotify audio. Install the optional emulator locally with
`python3 -m pip install unicorn==2.1.4` to include these checks in `make test`; CI requires it.

Transition regressions additionally cover normal-mode analysis/video shutdown, clips created or
resumed mid-transition, owner pauses, inactive interruptions and recovery. The existing generation-
checked transition-end/timeout logic applies the same policy to covers and visualizer inputs.
