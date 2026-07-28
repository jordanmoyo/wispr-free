#!/bin/bash
# Builds, signs (Developer ID), notarizes, staples, and zips a release.
# Usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.1.0
#
# One-time setup (interactive, uses your Apple Developer account):
#   xcrun notarytool store-credentials wispr-notary
# Identity override: WISPR_RELEASE_IDENTITY (defaults to the first
# "Developer ID Application" identity in the default keychain search list).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"

PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
    echo "error: Info.plist CFBundleShortVersionString is $PLIST_VERSION, expected $VERSION" >&2
    exit 1
fi

IDENTITY="${WISPR_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
    echo "error: no 'Developer ID Application' identity found (set WISPR_RELEASE_IDENTITY)" >&2
    exit 1
fi
echo "Signing identity: $IDENTITY"

if ! xcrun notarytool history --keychain-profile wispr-notary >/dev/null 2>&1; then
    echo "error: notarytool keychain profile 'wispr-notary' not found." >&2
    echo "One-time setup: xcrun notarytool store-credentials wispr-notary" >&2
    exit 1
fi

swift test

./scripts/assemble_app.sh
APP="dist/Wispr Free.app"

# Hardened runtime + secure timestamp are required for notarization.
# The app itself also needs the audio-input entitlement: under the hardened
# runtime, macOS denies the microphone without it (silently — no prompt).
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
codesign --force --options runtime --timestamp \
    --entitlements Resources/Wispr.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

SUBMIT_ZIP="dist/notarize-upload.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile wispr-notary --wait
rm "$SUBMIT_ZIP"

xcrun stapler staple "$APP"

RELEASE_ZIP="dist/WisprFree-${VERSION}-arm64.zip"
ditto -c -k --keepParent "$APP" "$RELEASE_ZIP"

spctl -a -t exec -vv "$APP" 2>&1 | grep -q "Notarized Developer ID" \
    || { echo "error: Gatekeeper assessment did not report Notarized Developer ID" >&2; exit 1; }

echo "Release ready: $RELEASE_ZIP"
