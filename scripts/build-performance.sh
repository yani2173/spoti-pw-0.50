#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/out/SGPerformance050.dylib}"
mkdir -p "$(dirname "$OUT")"
xcrun --sdk iphoneos clang -target arm64-apple-ios16.1 -dynamiclib -fobjc-arc -Os \
  -Wall -Wextra -Werror "$ROOT/performance/SGPerformance.m" \
  -framework Foundation -framework UIKit -framework QuartzCore \
  -install_name @rpath/SGPerformance050.dylib -o "$OUT"
