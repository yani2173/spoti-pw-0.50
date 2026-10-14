# spoti.pw 0.51.0 packaging and performance add-on

Read `docs/tweaks.md` and `performance/README.md` before changes.

- The original 0.51.0 core is compiled upstream code in `vendor/releases/0.51.0/`.
- Editable runtime fixes live in `performance/`; packaging code lives in `scripts/`.
- The old 0.22.0 source and its build system were removed. Historical upstream tags still
  refer to their original commits; do not treat their source as the installed 0.51.0 implementation.
- Never relabel an older source build as a newer release. Preserve the original kit checksums
  and final Mach-O core section verification.
- Prove private classes/selectors against the actual pinned binary and guard their signatures.
- Preserve owner pause states, main-thread UI access, and original frame-rate requests.
- `make release` and `make build` both package optimized 0.51.0; `make release-official`
  packages the original. Quote IPA paths. No Theos build is part of this checkout.
- Run `make test`. Runtime changes also require the macOS Objective-C tests and an arm64 iOS
  build in `.github/workflows/check-performance.yml`. Packaging changes require the real-kit matrix.
- Keep original licenses and release attribution. Do not claim measured device improvements
  from stand-in runtime tests or synthetic IPA packaging tests.
