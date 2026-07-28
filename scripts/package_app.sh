#!/bin/bash
# Builds and signs a local dev copy of Wispr Free at "dist/Wispr Free.app".
#
# Signing config (all optional, no secrets in the repo):
#   WISPR_SIGN_IDENTITY           codesign identity name
#   WISPR_SIGN_KEYCHAIN           keychain holding it (optional)
#   WISPR_SIGN_KEYCHAIN_PASSWORD  password to unlock that keychain (optional)
# Unset -> ad-hoc signing. Ad-hoc rebuilds get a new code signature each
# time, so macOS TCC permission grants (Microphone / Input Monitoring /
# Accessibility) must be re-granted after every rebuild. For frequent dev,
# create a stable self-signed identity and export the vars above
# (see CONTRIBUTING.md).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/assemble_app.sh

APP="dist/Wispr Free.app"
IDENTITY="${WISPR_SIGN_IDENTITY:-}"
KEYCHAIN="${WISPR_SIGN_KEYCHAIN:-}"

if [[ -n "$IDENTITY" ]]; then
    ARGS=(--force --sign "$IDENTITY")
    if [[ -n "$KEYCHAIN" ]]; then
        if [[ -n "${WISPR_SIGN_KEYCHAIN_PASSWORD:-}" ]]; then
            security unlock-keychain -p "$WISPR_SIGN_KEYCHAIN_PASSWORD" "$KEYCHAIN"
        fi
        ARGS+=(--keychain "$KEYCHAIN")
    fi
    codesign "${ARGS[@]}" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
    codesign "${ARGS[@]}" "$APP"
else
    codesign --force --sign - "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
