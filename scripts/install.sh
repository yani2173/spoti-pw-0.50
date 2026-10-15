#!/usr/bin/env bash
# Signs an IPA with your own certificate and installs it on the iPhone plugged into this Mac.
#
#   scripts/install.sh out/spoti.pw-0.51.0-optimized.ipa
#
# Put the certificate details in .signing.env (gitignored):
#   SIGN_P12=/path/to/cert.p12
#   SIGN_PROFILE=/path/to/profile.mobileprovision
#   SIGN_P12_PASSWORD=...
# WIFI=1 installs over Wi-Fi instead of USB (the phone must be paired for wireless sync).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/.signing.env" ] && . "$ROOT/.signing.env"
cd "$ROOT"
: "${SIGN_P12:?set SIGN_P12 in .signing.env}" "${SIGN_PROFILE:?set SIGN_PROFILE in .signing.env}" "${SIGN_P12_PASSWORD:?set SIGN_P12_PASSWORD in .signing.env}"

IN="${1:?usage: $0 <ipa>}"
SIGNED="${IN%.ipa}-signed.ipa"

command -v zsign >/dev/null || { echo "missing zsign -> brew install zsign" >&2; exit 1; }
command -v ideviceinstaller >/dev/null || { echo "missing ideviceinstaller -> brew install ideviceinstaller" >&2; exit 1; }

# The bundle id has to equal the App ID of the profile. iOS may well install a mismatched pair, but
# MediaRemote launches the now playing app by its application-identifier entitlement rather than by
# CFBundleIdentifier, so tapping the lock screen card then asks for a bundle that does not exist and
# nothing opens. A wildcard App ID needs no rewrite: the entitlement takes the IPA's own bundle id.
command -v python3 >/dev/null || { echo "missing python3" >&2; exit 1; }
PROFILE_PLIST="$(mktemp)"
trap 'rm -f "$PROFILE_PLIST"' EXIT
security cms -D -i "$SIGN_PROFILE" > "$PROFILE_PLIST" 2>/dev/null
APP_ID="$(python3 "$ROOT/scripts/signing-bundle-id.py" "$PROFILE_PLIST" "$IN")"
INSTALL_ARGS=()
case "${WIFI:-0}" in
  0) ;;
  1) INSTALL_ARGS+=(-n) ;;
  *) echo "WIFI must be 0 or 1" >&2; exit 1 ;;
esac

echo "==> signing as $APP_ID"
zsign -k "$SIGN_P12" -p "$SIGN_P12_PASSWORD" -m "$SIGN_PROFILE" -b "$APP_ID" -z 1 -o "$SIGNED" "$IN" >/dev/null
echo "==> installing $SIGNED"
ideviceinstaller "${INSTALL_ARGS[@]}" install "$SIGNED" 2>&1 | tail -3
