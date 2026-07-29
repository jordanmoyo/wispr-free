#!/bin/bash
# Updates the Homebrew tap with a new Wispr Free cask version.
# Usage: scripts/update_cask.sh <version>   e.g. scripts/update_cask.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/update_cask.sh <version>}"
ZIP="dist/WisprFree-${VERSION}-arm64.zip"

if [[ ! -f "$ZIP" ]]; then
    echo "error: $ZIP does not exist" >&2
    exit 1
fi

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

# Tap checkout: reuse $WISPR_TAP_DIR if set and a git repo, else clone.
if [[ -n "${WISPR_TAP_DIR:-}" ]] && [[ -d "$WISPR_TAP_DIR/.git" ]]; then
    TAP_DIR="$WISPR_TAP_DIR"
else
    TAP_DIR=$(mktemp -d)
    git clone git@github.com:jordanmoyo/homebrew-tap.git "$TAP_DIR"
fi

# Create Casks directory and sed the template.
mkdir -p "$TAP_DIR/Casks"
CASK_FILE="$TAP_DIR/Casks/wispr-free.rb"
sed "s/__VERSION__/$VERSION/g; s/__SHA256__/$SHA/g" packaging/wispr-free.rb.template > "$CASK_FILE"

# Stage first, then compare against HEAD: a plain `git diff` ignores
# untracked files, so on the first run against a fresh tap (no cask yet)
# it would report "no changes" and silently skip the commit and push.
# Staging also handles the empty-repo case (no HEAD at all → commit).
git -C "$TAP_DIR" add "$CASK_FILE"
if git -C "$TAP_DIR" rev-parse --verify HEAD >/dev/null 2>&1 \
   && git -C "$TAP_DIR" diff --cached --quiet HEAD; then
    echo "cask unchanged"
else
    git -C "$TAP_DIR" commit -m "wispr-free $VERSION"
fi

# Always push: if a previous run committed but its push failed, the stuck
# commit goes out now; when everything is already on the remote this is a
# no-op ("Everything up-to-date").
git -C "$TAP_DIR" push origin HEAD

echo "done"
