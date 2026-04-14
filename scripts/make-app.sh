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
# Document type bindings declared in Info.plist:
#   - .tr0 → Owner (LaunchServices default handler for OmegaSim TR0 binary)
#   - .out → Alternate (appears in "Open With" but doesn't replace TextEdit
#                       as the default — the user explicitly asked for this)
# The script regenerates the icon set from icon.png at every build and
# re-registers the bundle with LaunchServices so the new doc types and icon
# show up without requiring a logout.
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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SOURCE="$REPO_ROOT/icon.png"

if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Missing icon source at $ICON_SOURCE" >&2
    exit 1
fi

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

# --- Icon: build a .icns from icon.png ---------------------------------------
#
# `iconutil` requires an `.iconset` directory containing the canonical 10
# rasters. The 1024x1024 source already covers the largest size; sips
# down-samples it to every smaller variant.
echo "==> Generating WaveformViewer.icns from $(basename "$ICON_SOURCE")"
ICONSET="$BUILD_DIR/${APP_NAME}.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size       $size       "$ICON_SOURCE" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) "$ICON_SOURCE" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/${APP_NAME}.icns"
rm -rf "$ICONSET"

# --- Info.plist --------------------------------------------------------------
#
# Single-quoted heredoc — no shell variable expansion inside.
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

    <!-- Icon (extension omitted — LaunchServices appends .icns) -->
    <key>CFBundleIconFile</key>
    <string>WaveformViewer</string>

    <!-- Document type bindings.
         .tr0 → Owner: WaveformViewer becomes the default app for TR0 files.
         .out → Alternate: appears in the "Open With" submenu but never
                replaces the user's existing default (typically TextEdit). -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>OmegaSim TR0 Waveform</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.jcroix.WaveformViewer.tr0</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>SPICE Listing Output</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.jcroix.WaveformViewer.spice-listing</string>
            </array>
        </dict>
    </array>

    <!-- Exported UTIs.
         Both are scoped to their specific extension only, so declaring them
         doesn't accidentally claim every binary file (`public.data`) or every
         text file (`public.plain-text`) in the system. -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.jcroix.WaveformViewer.tr0</string>
            <key>UTTypeDescription</key>
            <string>OmegaSim TR0 Waveform</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeIconFile</key>
            <string>WaveformViewer</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>tr0</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.jcroix.WaveformViewer.spice-listing</string>
            <key>UTTypeDescription</key>
            <string>SPICE Listing Output</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeIconFile</key>
            <string>WaveformViewer</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>out</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# --- LaunchServices refresh --------------------------------------------------
#
# Without this, the new doc-type bindings can take a long time (or a logout)
# to propagate. `lsregister -f -R <app>` forces an immediate re-scan of the
# bundle so .tr0 → WaveformViewer takes effect right away.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    echo "==> Refreshing LaunchServices database"
    "$LSREGISTER" -f -R "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "==> Built $APP_DIR"
echo "Launch with: open $APP_DIR"
