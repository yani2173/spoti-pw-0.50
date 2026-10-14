<p align="center">
  <img src="docs/icon.png" width="96" alt="">
</p>

<h1 align="center">spoti.pw</h1>

<p align="center">Spotify, in glass.</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-000000?style=for-the-badge&logo=ios&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/Spotify-9.1.90-1ED760?style=for-the-badge&logo=spotify&logoColor=white" alt="Spotify 9.1.90">
  <img src="https://img.shields.io/badge/Objective--C-3A95E3?style=for-the-badge&logo=apple&logoColor=white" alt="Objective-C">
  <img src="https://img.shields.io/badge/GitHub_Actions-2671E5?style=for-the-badge&logo=githubactions&logoColor=white" alt="GitHub Actions">
  <img src="https://img.shields.io/badge/License-PolyForm_Strict_1.0.0-blue?style=for-the-badge" alt="PolyForm Strict 1.0.0">
</p>

<p align="center">
  <a href="https://spoti.pw">spoti.pw</a> ·
  <a href="#build-it">Build it</a> ·
  <a href="docs/tweaks.md">Hack on it</a> ·
  <a href="https://ko-fi.com/darkksh">Support</a>
</p>

<p align="center">
  <img src="docs/screenshots/now-playing.webp" width="16%" alt="Full screen player with lyrics">
  <img src="docs/screenshots/album.webp" width="16%" alt="Album">
  <img src="docs/screenshots/playlist.webp" width="16%" alt="Playlist">
  <img src="docs/screenshots/queue.webp" width="16%" alt="Queue">
  <img src="docs/screenshots/live-activity.webp" width="16%" alt="Live Activity on the lock screen">
  <img src="docs/screenshots/home.webp" width="16%" alt="Home">
</p>

A no-jailbreak Theos tweak that rebuilds Spotify for iOS in Liquid Glass, injected into your own
decrypted IPA and signed with your own certificate.

The official **0.51.0** kit supports **Spotify 9.1.90 and 9.1.78**. Use a clean decrypted IPA of
one of these versions; other releases have different classes and are rejected by the builder.

| | |
|---|---|
| The redesign | **iOS 26+** |
| Legacy look | iOS 16.1+ |
| Live Activity | iOS 17+ |

The redesign is `UIGlassEffect`, which only exists from iOS 26. Below that the Redesigned UI switch
is greyed out and the mod runs Spotify's own screens with everything else it adds on top. Both live
in Settings → Mod Settings.

## Build it

No IPA is distributed. Bring a decrypted **Spotify 9.1.90 or 9.1.78** IPA; you get an unsigned
`spoti.pw-<mod version>.ipa` to sign with SideStore, Feather or any certificate signer. Each
[release](https://github.com/skopevoj/spoti.pw/releases) also carries the tweak's `.deb`.

### Build with GitHub Actions

Fork the repo, enable Actions, run **Build IPA from your own Spotify IPA**. It takes a direct link to
your decrypted `.ipa` and hands the built IPA back as a workflow artifact. No Mac needed; the link is
masked in the log and the result stays in your fork.

This repository retains the original public `v0.51.0` tag and its official compiled release files
under `vendor/releases/0.51.0/`. The public source at that tag identifies itself as **0.22.0**;
the IPA workflow uses the actual compiled **0.51.0** kit, rather than rebuilding that older source.

The workflow offers two modes:

- **optimized-0.51.0** (default): original 0.51.0 plus an independent performance add-on. It breaks
  the lyrics view/display-link retention cycle and suspends lyrics animation while the app is inactive,
  including late-created links and background launches. Links are cleaned up when their view is released,
  even while paused. During player opening/closing transitions, lyrics, moving-background and visualizer
  display links are suspended until completion. Original owner pauses, callback arguments and normal
  frame-rate settings are preserved.
- **official-0.51.0**: the unmodified official build, for comparison.

Both modes verify the official kit's published SHA-256 and compare the final core's Mach-O code/data
sections to that kit after signing. The optimized output is `spoti.pw-0.51.0-optimized.ipa`.
The builder rejects encrypted main executables and verifies that the app loads every required mod dylib.
Download **spoti.ipa** from the workflow's Artifacts, unzip it, then sign/install the enclosed IPA.
Use a clean decrypted Spotify 9.1.90 or 9.1.78 IPA with no existing spoti.pw injection.

In the optimized build, open **Mod Settings → Performance → Light mode** to keep moving backgrounds
and the visualizer still and pause animated player covers. The switch is off by default, applies
immediately and persists across launches. Music controls and synchronized lyrics stay available.
Turning it off restores the visual effects requested by the app without overriding its pause states.
The bottom of Mod Settings also has **Modified by Yani**; tap it to open https://yaniminchev.eu.

The add-on is described in [performance/README.md](performance/README.md), including the ABI evidence
from the real 0.51.0 binary. These are lifecycle and transition-workload optimizations; device frame pacing, memory, and battery
use still need testing on an iPhone. It does not refactor the unavailable 0.51.0 source or hide its version.

Local commands:

    make release-optimized IPA="/path/to/decrypted Spotify 9.1.90.ipa"  # Xcode + Python 3.11+, cyan, ldid, unzip, zip
    make release-official IPA="/path/to/decrypted Spotify 9.1.90.ipa"   # same tools without an Xcode compilation

`make release` below still builds the older public source. For packaging tests run
`python3 -m unittest discover -s tests -v`; set `SG_OFFICIAL_KIT` and put cyan/ldid on PATH for the
real-kit test with synthetic executables. CI also runs the add-on's Objective-C tests on macOS
and compiles its iOS dylib.

### Build on a Mac

Theos in `~/theos` and Xcode with an iPhoneOS 26+ SDK (`xcode-select` it). An SDK in `~/theos/sdks`
alone builds too, but without the Live Activity. Then:

    brew install make ldid dpkg zsign ideviceinstaller libimobiledevice
    uv tool install "cyan @ git+https://github.com/asdfzxcvbn/pyzule-rw"

Put the decrypted `.ipa` in `ipa/`, then:

    make release    # out/spoti.pw-<version>.ipa, ready to sign
    make install    # the same, signed with your certificate and pushed over USB

`make install` reads `SIGN_P12`, `SIGN_PROFILE` and `SIGN_P12_PASSWORD` from `.signing.env`; copy
`.signing.env.example` and fill it in.

The first build spends a minute reading Spotify's flags out of your IPA. `make flags` regenerates it.

### Signing

Sign with a bundle id matching your certificate's App ID. If it doesn't match, the app still works
but tapping the player on the lock screen won't open it — and it tells you on first launch which id
to use. In Feather, copy the App ID into **Identifier** and leave **PPQ protection** off; AltStore,
SideStore and Sideloadly get this right on their own.

The app keeps Spotify's bundle id, so it installs over the real Spotify.

## Support

If it made your phone nicer to use, a coffee is a good way to say so.

<a href="https://ko-fi.com/darkksh">
  <img src="https://img.shields.io/badge/Ko--fi-Buy_me_a_coffee-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white" alt="Support on Ko-fi">
</a>

## Contributing

Pull requests are welcome. The pull request's description has a box for agreeing to the
[Contributor License Agreement](CLA.md), which gives the project's owner the rights to the
contribution; it is ticked once, before the first pull request is merged.

## Star history

<a href="https://star-history.com/#skopevoj/spoti.pw&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=skopevoj/spoti.pw&type=Date&theme=dark">
    <img src="https://api.star-history.com/svg?repos=skopevoj/spoti.pw&type=Date" alt="Star history chart">
  </picture>
</a>

## Credits

[cyan](https://github.com/asdfzxcvbn/pyzule-rw) injects, [Theos](https://theos.dev) builds, and
[FLEX](https://github.com/FLEXTool/FLEX), as hopeless's AutoFLEX build in `vendor/`, is the inspector
the view trees are read through.

## License

Source available under the [PolyForm Strict License 1.0.0](LICENSE): you can read the code and use
the mod yourself, but not change it, reuse it in other projects or redistribute it. Releases up to
v0.21.1 were published under GPL-3.0 and stay under it. Files in `vendor/` and `.agents/` keep their
own licences.

Not affiliated with Spotify.
