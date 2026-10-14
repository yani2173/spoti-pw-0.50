#!/usr/bin/env bash
# Build the actual official 0.51.0 release, using its prebuilt kit rather than this checkout's source.
# Usage: scripts/official-release.sh <decrypted Spotify 9.1.90.ipa> [output.ipa]
# Needs python3 (3.11+), cyan, ldid, unzip and zip. SG_OPTIMIZE=1 also builds the iOS add-on with Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IN="${1:?usage: $0 <decrypted Spotify 9.1.90.ipa> [output.ipa]}"
OPTIMIZE="${SG_OPTIMIZE:-0}"
case "$OPTIMIZE" in 0|1) ;; *) echo "SG_OPTIMIZE must be 0 or 1" >&2; exit 1 ;; esac
SUFFIX=""
[ "$OPTIMIZE" = 0 ] || SUFFIX="-optimized"
OUT="${2:-$ROOT/out/spoti.pw-0.51.0$SUFFIX.ipa}"
for tool in python3 cyan ldid unzip zip; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done
[ -f "$IN" ] || { echo "no such IPA: $IN" >&2; exit 1; }
python3 - "$IN" "$OUT" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).resolve() == pathlib.Path(sys.argv[2]).resolve():
    sys.exit("The output must differ from the original IPA")
PY

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
# This repository carries the unmodified official kit. Its published checksum is always checked.
KIT="${SG_OFFICIAL_KIT:-$ROOT/vendor/releases/0.51.0/spoti.pw-0.51.0-kit.zip}"
if [ ! -f "$KIT" ] && [ -z "${SG_OFFICIAL_KIT:-}" ]; then
  KIT="$BUILD_DIR/official-kit.zip"
  curl -fsSL --retry 3 --max-time 120 \
    https://github.com/skopevoj/spoti.pw/releases/download/v0.51.0/spoti.pw-0.51.0-kit.zip -o "$KIT"
fi
APP_DIR="$(python3 "$ROOT/scripts/prepare-official-kit.py" "$IN" "$KIT" "$BUILD_DIR/kit")"
echo "==> injecting official spoti.pw 0.51.0 into a compatible Spotify IPA"
FILES=("$BUILD_DIR/kit/files/Frameworks/SpotifyGlassAppGroups.dylib"
       "$BUILD_DIR/kit/files/Frameworks/spotifyglass.dylib"
       "$BUILD_DIR/kit/files/PlugIns/SpotifyGlassLiveActivity.appex")
if [ "$OPTIMIZE" = 1 ]; then
  ADDON="${SG_PERFORMANCE_DYLIB:-$BUILD_DIR/SGPerformance051.dylib}"
  if [ -z "${SG_PERFORMANCE_DYLIB:-}" ]; then "$ROOT/scripts/build-performance.sh" "$ADDON"; fi
  [ -f "$ADDON" ] && [ "$(basename "$ADDON")" = SGPerformance051.dylib ] \
    || { echo "missing SGPerformance051.dylib" >&2; exit 1; }
  FILES+=("$ADDON")
fi
cyan -i "$IN" -o "$BUILD_DIR/injected.ipa" -f "${FILES[@]}" \
  -l "$BUILD_DIR/kit/host.plist" -w --overwrite

# The home screen widget needs the same App Group shim as the app. Its presence is optional in the kit.
WIDGET_BIN="${APP_DIR}PlugIns/WidgetExtension.appex/WidgetExtension"
if unzip -l "$BUILD_DIR/injected.ipa" "$WIDGET_BIN" >/dev/null 2>&1; then
  unzip -q "$BUILD_DIR/injected.ipa" "$WIDGET_BIN" -d "$BUILD_DIR/widget"
  python3 "$ROOT/scripts/insert-dylib.py" "$BUILD_DIR/widget/$WIDGET_BIN" @rpath/SpotifyGlassAppGroups.dylib
  # cyan's final signing pass preserves this widget's entitlements and updates its signature.
  (cd "$BUILD_DIR/widget" && zip -q "$BUILD_DIR/injected.ipa" "$WIDGET_BIN")
fi
python3 "$ROOT/scripts/merge-appintents.py" "$BUILD_DIR/injected.ipa" "$APP_DIR" "$BUILD_DIR/kit/appintents"

# All plist and binary changes precede the final signing pass. SideStore/Feather then signs for the user.
cyan -i "$BUILD_DIR/injected.ipa" -o "$BUILD_DIR/final.ipa" -s --overwrite
python3 "$ROOT/scripts/verify-official-build.py" "$BUILD_DIR/final.ipa" "$KIT" "$OPTIMIZE"
mkdir -p "$(dirname "$OUT")"
mv "$BUILD_DIR/final.ipa" "$OUT"
echo "==> done: $OUT (original 0.51.0 core, performance add-on: $OPTIMIZE; sign with your own signer)"
