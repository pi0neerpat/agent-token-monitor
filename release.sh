#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
APP_NAME="Agent Token Monitor.app"
APP_DIR="$DIST_DIR/$APP_NAME"
DMG_PATH="$DIST_DIR/AgentTokenMonitor.dmg"
RW_DMG_PATH="$DIST_DIR/AgentTokenMonitor-temp.dmg"
STAGING_DIR="$DIST_DIR/dmg-root"
MODULE_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/agent-token-monitor-module-cache.XXXXXX")"
ICON_SRC="$SCRIPT_DIR/app-icon.png"
MENU_BAR_ICON_SRC="$SCRIPT_DIR/assets/clawd.png"
CODEX_ICON_SRC="$SCRIPT_DIR/assets/codex-icon.png"
DMG_BACKGROUND_SRC="$SCRIPT_DIR/build/dmg-background.png"
BUILD_DIR="$SCRIPT_DIR/.build"
ARM64_BIN="$BUILD_DIR/agent-token-monitor-arm64"
X64_BIN="$BUILD_DIR/agent-token-monitor-x86_64"
UNIVERSAL_BIN="$APP_DIR/Contents/MacOS/agent-token-monitor"
# Exclude Package.swift (SwiftPM manifest; not app source).
SWIFT_SOURCES=()
for f in "$SCRIPT_DIR"/*.swift; do
  [[ -f "$f" ]] || continue
  [[ "$(basename "$f")" == "Package.swift" ]] && continue
  SWIFT_SOURCES+=("$f")
done
MACOS_TARGET="13.0"
BUNDLE_ID="com.scribular.agent-token-monitor"
DESIGNATED_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""
VOLUME_NAME="Agent Token Monitor"
DMG_WIDTH=660
DMG_HEIGHT=400
APP_ICON_X=180
APP_ICON_Y=170
APPLICATIONS_ICON_X=480
APPLICATIONS_ICON_Y=170
SIGNING_MODE="${1:-test}"
APP_VERSION="${APP_VERSION:-}"
APPLE_IDENTITY="${APPLE_IDENTITY:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_ID_PASSWORD="${APPLE_ID_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

trap 'rm -rf "$MODULE_CACHE"' EXIT

if [[ "$SIGNING_MODE" != "test" && "$SIGNING_MODE" != "sandbox" && "$SIGNING_MODE" != "release" ]]; then
    echo "Usage: ./release.sh [test|sandbox|release]"
    echo "  test     Build a tester-friendly ad-hoc app without sandbox entitlements."
    echo "  sandbox  Build an ad-hoc app with sandbox entitlements for local validation."
    echo "  release  Build, Developer ID sign, notarize, and staple a distributable DMG."
    exit 1
fi

if [[ "$SIGNING_MODE" == "release" ]]; then
    for required_var in APP_VERSION APPLE_IDENTITY APPLE_ID APPLE_ID_PASSWORD APPLE_TEAM_ID; do
        if [[ -z "${!required_var:-}" ]]; then
            echo "Missing required environment variable for release signing: $required_var"
            exit 1
        fi
    done
fi

echo "Preparing release build ($SIGNING_MODE)..."
if [[ -n "$APP_VERSION" ]]; then
    echo "Using app version: $APP_VERSION"
else
    CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SCRIPT_DIR/Info.plist")
    echo "Using Info.plist version: $CURRENT_VERSION"
fi

/bin/chmod -R u+w "$DIST_DIR" 2>/dev/null || true
/bin/rm -rf "$APP_DIR" "$DMG_PATH" "$RW_DMG_PATH" "$STAGING_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$STAGING_DIR" "$BUILD_DIR"

cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/"
cp "$MENU_BAR_ICON_SRC" "$APP_DIR/Contents/Resources/clawd.png"
cp "$CODEX_ICON_SRC" "$APP_DIR/Contents/Resources/codex-icon.png"
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
    "${SWIFT_SOURCES[@]}" \
    -o "$ARM64_BIN" \
    -target "arm64-apple-macos${MACOS_TARGET}" \
    -framework Cocoa \
    -framework Foundation \
    -framework Security

swiftc \
    -module-cache-path "$MODULE_CACHE" \
    "${SWIFT_SOURCES[@]}" \
    -o "$X64_BIN" \
    -target "x86_64-apple-macos${MACOS_TARGET}" \
    -framework Cocoa \
    -framework Foundation \
    -framework Security

lipo -create -output "$UNIVERSAL_BIN" "$ARM64_BIN" "$X64_BIN"

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
    codesign \
        --force \
        --sign - \
        --requirements "$DESIGNATED_REQUIREMENT" \
        --entitlements "$SCRIPT_DIR/entitlements.plist" \
        "$APP_DIR"
else
    codesign \
        --force \
        --sign - \
        --requirements "$DESIGNATED_REQUIREMENT" \
        "$APP_DIR"
fi

cp -R "$APP_DIR" "$STAGING_DIR/"
mkdir -p "$STAGING_DIR/.background"
cp "$DMG_BACKGROUND_SRC" "$STAGING_DIR/.background/background.png"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -ov \
    -fs HFS+ \
    -size 200m \
    "$RW_DMG_PATH"

ATTACH_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG_PATH")
DEVICE_NAME=$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {print $1; exit}')
VOLUME_PATH=$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {$1=$2=""; sub(/^[ \t]+/, ""); print; exit}')

if [[ -z "$DEVICE_NAME" || -z "$VOLUME_PATH" ]]; then
    echo "Failed to determine mounted DMG device or volume path"
    printf '%s\n' "$ATTACH_OUTPUT"
    exit 1
fi

/bin/cp -R "$APP_DIR" "$VOLUME_PATH/"
/bin/mkdir -p "$VOLUME_PATH/.background"
/bin/cp "$DMG_BACKGROUND_SRC" "$VOLUME_PATH/.background/background.png"
ln -s /Applications "$VOLUME_PATH/Applications"

osascript <<EOF
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, $((100 + DMG_WIDTH)), $((100 + DMG_HEIGHT))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 160
        set background picture of viewOptions to file ".background:background.png"
        set position of item "$APP_NAME" of container window to {$APP_ICON_X, $APP_ICON_Y}
        set position of item "Applications" of container window to {$APPLICATIONS_ICON_X, $APPLICATIONS_ICON_Y}
        update without registering applications
        delay 2
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

/usr/bin/chflags hidden "$VOLUME_PATH/.background" 2>/dev/null || true
/usr/bin/chflags hidden "$VOLUME_PATH/.fseventsd" 2>/dev/null || true

chmod -Rf go-w "$VOLUME_PATH" || true
sync
hdiutil detach "$DEVICE_NAME"

hdiutil convert "$RW_DMG_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$RW_DMG_PATH"

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
