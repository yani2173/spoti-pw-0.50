#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/out/SGPerformance051.dylib}"
mkdir -p "$(dirname "$OUT")"
xcrun --sdk iphoneos clang -target arm64-apple-ios16.1 -dynamiclib -fobjc-arc -Os \
  -Wall -Wextra -Werror "$ROOT/performance/SGPerformance.m" "$ROOT/performance/SGPerfSettings.m" "$ROOT/performance/SGLyricsRepair.m" "$ROOT/performance/SGLightRendering.m" \
  -framework Foundation -framework UIKit -framework QuartzCore -framework MediaPlayer \
  -install_name @rpath/SGPerformance051.dylib -o "$OUT"
