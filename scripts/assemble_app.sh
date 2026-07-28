#!/bin/bash
# Builds the app with xcodebuild and assembles the UNSIGNED bundle at
# dist/Wispr Free.app. Callers (package_app.sh, release.sh) sign it.
set -euo pipefail
cd "$(dirname "$0")/.."

# swift build cannot compile MLX's Metal shaders; xcodebuild can, and emits
# mlx-swift_Cmlx.bundle (default.metallib) that must ship with the app.
xcodebuild -scheme Wispr -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .build/xcode \
    -skipMacroValidation -skipPackagePluginValidation \
    build

PRODUCTS=".build/xcode/Build/Products/Release"
APP="dist/Wispr Free.app"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$PRODUCTS/Wispr" "$APP/Contents/MacOS/Wispr"
# MLX's metallib search (mlx device.cpp load_default_library) probes
# <bundle resourceURL>/mlx-swift_Cmlx.bundle — i.e. Contents/Resources for a
# .app. Contents/MacOS is NOT searched; placing it there aborts the process
# with "Failed to load the default metallib" on first inference.
cp -R "$PRODUCTS/mlx-swift_Cmlx.bundle" "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

echo "Assembled $APP (unsigned)"
