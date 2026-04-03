#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
APP_NAME="Claude Token Meter.app"
APP_DIR="$DIST_DIR/$APP_NAME"
DMG_PATH="$DIST_DIR/ClaudeTokenMeter.dmg"
STAGING_DIR="$DIST_DIR/dmg-root"
MODULE_CACHE="$SCRIPT_DIR/.swift-module-cache"
ICON_SRC="$SCRIPT_DIR/app-icon.png"
MENU_BAR_ICON_SRC="$SCRIPT_DIR/clawd.png"
SIGNING_MODE="${1:-test}"
APP_VERSION="${APP_VERSION:-}"
APPLE_IDENTITY="${APPLE_IDENTITY:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_ID_PASSWORD="${APPLE_ID_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

if [[ "$SIGNING_MODE" != "test" && "$SIGNING_MODE" != "sandbox" && "$SIGNING_MODE" != "release" ]]; then
    echo "Usage: ./release.sh [test|sandbox|release]"
    echo "  test     Build a tester-friendly ad-hoc app without sandbox entitlements."
    echo "  sandbox  Build an ad-hoc app with sandbox entitlements for local validation."
    echo "  release  Build, Developer ID sign, notarize, and staple a distributable DMG."
    exit 1
fi

if [[ "$SIGNING_MODE" == "release" ]]; then
    for required_var in APPLE_IDENTITY APPLE_ID APPLE_ID_PASSWORD APPLE_TEAM_ID; do
        if [[ -z "${!required_var:-}" ]]; then
            echo "Missing required environment variable for release signing: $required_var"
            exit 1
        fi
    done
fi

echo "Preparing release build ($SIGNING_MODE)..."

rm -rf "$APP_DIR" "$DMG_PATH" "$STAGING_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$STAGING_DIR" "$MODULE_CACHE"

cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/"
cp "$MENU_BAR_ICON_SRC" "$APP_DIR/Contents/Resources/clawd.png"
ASSET_ROOT="$DIST_DIR/appicon-assets"
ASSET_CATALOG_DIR="$ASSET_ROOT/Assets.xcassets"
APPICONSET_DIR="$ASSET_CATALOG_DIR/AppIcon.appiconset"
PARTIAL_PLIST="$ASSET_ROOT/asset-info.plist"
rm -rf "$ASSET_ROOT"
mkdir -p "$APPICONSET_DIR"
cat > "$ASSET_CATALOG_DIR/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

sips -z 16 16 "$ICON_SRC" --out "$APPICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SRC" --out "$APPICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SRC" --out "$APPICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SRC" --out "$APPICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SRC" --out "$APPICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SRC" --out "$APPICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SRC" --out "$APPICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SRC" --out "$APPICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SRC" --out "$APPICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SRC" --out "$APPICONSET_DIR/icon_512x512@2x.png" >/dev/null

cat > "$APPICONSET_DIR/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

xcrun actool \
  --compile "$APP_DIR/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$PARTIAL_PLIST" \
  "$ASSET_CATALOG_DIR"

swiftc \
    -module-cache-path "$MODULE_CACHE" \
    "$SCRIPT_DIR/ClaudeTokenMeter.swift" \
    -o "$APP_DIR/Contents/MacOS/claude-token-meter" \
    -framework Cocoa \
    -framework Foundation \
    -framework Security

if [[ -n "$APP_VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP_DIR/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_DIR/Contents/Info.plist"
fi

if [[ "$SIGNING_MODE" == "release" ]]; then
    codesign \
        --force \
        --sign "$APPLE_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$SCRIPT_DIR/entitlements.plist" \
        "$APP_DIR"
elif [[ "$SIGNING_MODE" == "sandbox" ]]; then
    codesign --force --sign - --entitlements "$SCRIPT_DIR/entitlements.plist" "$APP_DIR"
else
    codesign --force --sign - "$APP_DIR"
fi

cp -R "$APP_DIR" "$STAGING_DIR/"

hdiutil create \
    -volname "Claude Token Meter" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [[ "$SIGNING_MODE" == "release" ]]; then
    codesign \
        --force \
        --sign "$APPLE_IDENTITY" \
        --timestamp \
        "$DMG_PATH"

    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_ID_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait

    xcrun stapler staple "$APP_DIR"
    xcrun stapler staple "$DMG_PATH"
fi

echo
echo "Created:"
echo "  App: $APP_DIR"
echo "  DMG: $DMG_PATH"
echo
if [[ "$SIGNING_MODE" == "test" ]]; then
    echo "Note: this is an ad-hoc tester build without sandbox entitlements."
    echo "On another Mac, Gatekeeper may still require Open Anyway because the app is not notarized."
elif [[ "$SIGNING_MODE" == "release" ]]; then
    echo "Note: this build is Developer ID signed, notarized, and stapled for distribution."
else
    echo "Note: this build includes sandbox entitlements but is still ad-hoc signed."
    echo "It is useful for local validation, not for distribution."
fi
