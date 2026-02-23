#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build-release"
APP_NAME="WebexMuteSync"
BUNDLE_ID="com.github.skooter210.WebexMuteSync"
MIN_MACOS="13.0"

# Signing config — set these env vars or create scripts/signing.env
# See scripts/signing.env.example for details
SIGNING_ENV="$SCRIPT_DIR/signing.env"
if [ -f "$SIGNING_ENV" ]; then
    # shellcheck source=/dev/null
    source "$SIGNING_ENV"
fi

SIGN_IDENTITY="${SIGN_IDENTITY:?Set SIGN_IDENTITY in scripts/signing.env or environment (e.g. 'Developer ID Application: Name (TEAMID)')}"
TEAM_ID="${TEAM_ID:?Set TEAM_ID in scripts/signing.env or environment (e.g. '38LB82FXCB')}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool}"

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
</dict>
</plist>
PLIST

echo "==> Code signing with Developer ID..."
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$BUILD_DIR/$APP_NAME.app"

echo "==> Verifying signature..."
codesign --verify --verbose=2 "$BUILD_DIR/$APP_NAME.app"

echo "==> Creating zip archive for notarization..."
cd "$BUILD_DIR"
rm -f "$APP_NAME.zip"
ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip"

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

echo ""
echo "Done! Output:"
echo "  App:  $BUILD_DIR/$APP_NAME.app"
echo "  Zip:  $BUILD_DIR/$APP_NAME.zip"
