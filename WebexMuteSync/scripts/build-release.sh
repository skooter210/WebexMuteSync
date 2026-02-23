#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build-release"
APP_NAME="WebexMuteSync"
BUNDLE_ID="com.github.skooter210.WebexMuteSync"
MIN_MACOS="13.0"
SKIP_NOTARIZE=false

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--skip-notarize]"
            echo ""
            echo "  --skip-notarize  Ad-hoc sign only (no Developer ID or notarization)"
            echo "                   Use this if you don't have an Apple Developer account."
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# Signing config — set these env vars or create scripts/signing.env
# See scripts/signing.env.example for details
if [ "$SKIP_NOTARIZE" = false ]; then
    SIGNING_ENV="$SCRIPT_DIR/signing.env"
    if [ -f "$SIGNING_ENV" ]; then
        # shellcheck source=/dev/null
        source "$SIGNING_ENV"
    fi

    SIGN_IDENTITY="${SIGN_IDENTITY:?Set SIGN_IDENTITY in scripts/signing.env or environment (e.g. 'Developer ID Application: Name (TEAMID)')}"
    TEAM_ID="${TEAM_ID:?Set TEAM_ID in scripts/signing.env or environment (e.g. '38LB82FXCB')}"
    KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool}"
fi

echo "==> Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

BINARY="$PROJECT_DIR/.build/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

echo "==> Creating .app bundle..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/Resources"

cp "$BINARY" "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$BUILD_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns"

cat > "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WebexMuteSync</string>
    <key>CFBundleIdentifier</key>
    <string>com.github.skooter210.WebexMuteSync</string>
    <key>CFBundleName</key>
    <string>WebexMuteSync</string>
    <key>CFBundleDisplayName</key>
    <string>Webex Mute Sync</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>WebexMuteSync checks if your Anker PowerConf S3 is connected via Bluetooth to recommend switching to USB for LED control.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>WebexMuteSync reads Webex mute button state to sync with your speakerphone LED.</string>
</dict>
</plist>
PLIST

echo "==> Stripping extended attributes..."
xattr -cr "$BUILD_DIR/$APP_NAME.app"

if [ "$SKIP_NOTARIZE" = true ]; then
    echo "==> Code signing (ad-hoc, skipping notarization)..."
    codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME.app"
else
    echo "==> Code signing with Developer ID..."
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$BUILD_DIR/$APP_NAME.app"
fi

echo "==> Verifying signature..."
codesign --verify --verbose=2 "$BUILD_DIR/$APP_NAME.app"

echo "==> Creating zip archive..."
cd "$BUILD_DIR"
rm -f "$APP_NAME.zip"
ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip"

if [ "$SKIP_NOTARIZE" = false ]; then
    echo "==> Submitting for notarization..."
    xcrun notarytool submit "$APP_NAME.zip" \
        --team-id "$TEAM_ID" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$APP_NAME.app"

    echo "==> Re-creating zip with stapled ticket..."
    rm -f "$APP_NAME.zip"
    ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip"
fi

echo ""
echo "Done! Output:"
echo "  App:  $BUILD_DIR/$APP_NAME.app"
echo "  Zip:  $BUILD_DIR/$APP_NAME.zip"
if [ "$SKIP_NOTARIZE" = true ]; then
    echo ""
    echo "Note: App is ad-hoc signed only. Users will need to right-click > Open"
    echo "the first time, or run: xattr -dr com.apple.quarantine $APP_NAME.app"
fi
