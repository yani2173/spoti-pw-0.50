# Working on this fork

This checkout targets the actual official **0.51.0** release and Spotify **9.1.90 / 9.1.78**.
The older public 0.22.0 source, Theos project, source-built extensions and their harnesses have
been removed. Git history and original upstream tags preserve their provenance.

## Layout

- `performance/`: editable Objective-C add-on, including Light mode and settings integration.
- `scripts/official-release.sh`: packages the pinned kit and optional add-on into a supplied IPA.
- `scripts/build-performance.sh`: builds the add-on with Xcode.
- `scripts/prepare-official-kit.py`, `verify-official-build.py`, `sg_macho.py`: input,
  integrity and load-command validation.
- `scripts/insert-dylib.py`, `merge-appintents.py`: widget and App Intents packaging helpers.
- `tests/`: packaging tests and the actual add-on exercised with UIKit stand-ins.
- `vendor/releases/0.51.0/`: unchanged official kit, DEB, checksums and provenance.
- `vendor/releases/0.50.0/`: earlier compiled assets retained only for provenance/rollback.

## Development and validation

Read [the add-on documentation](../performance/README.md) for verified 0.51.0 ABI details.
Changes to old code in upstream historical tags do not change this app. The upstream core source
for 0.51.0 is not available in this checkout. Runtime fixes must be scoped to the current binary,
use verified signatures and preserve the original core's packaged code/data sections.

Use `make release IPA="/path/to/Spotify.ipa"` for the optimized build, or
`make release-official IPA="/path/to/Spotify.ipa"` for comparison. Outputs go to `out/`.
The only local runtime compilation is the independent add-on; Theos is not needed.

Run `make test` locally. The Check 0.51.0 performance add-on workflow also compiles the iOS dylib,
runs Objective-C lifecycle tests, and checks all official/optimized, supported Spotify-version
and widget-presence packaging combinations using real tools and synthetic IPA fixtures.
Actual UI behavior, Sing processing and background playback require device testing.
