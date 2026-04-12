#!/bin/bash
#
# Build WaveformViewer as a proper macOS .app bundle with an Info.plist.
#
# `swift run` launches the executable without a bundle, so macOS treats it as a
# non-bundled process: NSHighResolutionCapable is effectively off, WindowServer
# uses a slow-path composite, and the result is noticeable idle CPU churn.
# Wrapping the binary in a real .app is the supported way to get the native
# rendering path.
#
# Usage:
#   ./scripts/make-app.sh              # debug build (default)
#   ./scripts/make-app.sh release      # release build
#
# After building, launch with:
#   open .build/<config>/WaveformViewer.app
#

set -euo pipefail

CONFIG="${1:-debug}"
case "$CONFIG" in
    debug|release) ;;
    *)
        echo "Unknown config: $CONFIG (expected 'debug' or 'release')" >&2
        exit 1
        ;;
esac

APP_NAME="WaveformViewer"
BUILD_DIR=".build/$CONFIG"
BINARY="$BUILD_DIR/$APP_NAME"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

if [[ ! -f "$BINARY" ]]; then
    echo "Missing built binary at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY" "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Waveform Viewer</string>
    <key>CFBundleExecutable</key>
    <string>WaveformViewer</string>
    <key>CFBundleIdentifier</key>
    <string>com.jcroix.WaveformViewer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>WaveformViewer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
</dict>
</plist>
PLIST

echo "==> Built $APP_DIR"
echo "Launch with: open $APP_DIR"
