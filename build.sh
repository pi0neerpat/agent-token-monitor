#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Claude Token Meter.app"
ICON_SRC="$SCRIPT_DIR/app-icon.png"
MENU_BAR_ICON_SRC="$SCRIPT_DIR/assets/clawd.png"
BUILD_DIR="$SCRIPT_DIR/.build"
ARM64_BIN="$BUILD_DIR/claude-token-meter-arm64"
X64_BIN="$BUILD_DIR/claude-token-meter-x86_64"
UNIVERSAL_BIN="$APP/Contents/MacOS/claude-token-meter"
MACOS_TARGET="13.0"

# Create .app bundle structure
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$BUILD_DIR"

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP/Contents/"
cp "$MENU_BAR_ICON_SRC" "$APP/Contents/Resources/clawd.png"

# Compile universal Swift binary
swiftc "$SCRIPT_DIR/ClaudeTokenMeter.swift" \
    -o "$ARM64_BIN" \
    -target "arm64-apple-macos${MACOS_TARGET}" \
    -framework Cocoa \
    -framework Foundation \
    -framework Security

swiftc "$SCRIPT_DIR/ClaudeTokenMeter.swift" \
    -o "$X64_BIN" \
    -target "x86_64-apple-macos${MACOS_TARGET}" \
    -framework Cocoa \
    -framework Foundation \
    -framework Security

lipo -create -output "$UNIVERSAL_BIN" "$ARM64_BIN" "$X64_BIN"

# Compile app icon asset catalog
ASSET_ROOT=$(mktemp -d)
APPICONSET_DIR="$ASSET_ROOT/AppIcon.appiconset"
ASSET_CATALOG_DIR="$ASSET_ROOT/Assets.xcassets"
PARTIAL_PLIST="$ASSET_ROOT/asset-info.plist"
mkdir -p "$APPICONSET_DIR" "$ASSET_CATALOG_DIR"
cat > "$ASSET_CATALOG_DIR/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

sips -z 16 16     "$ICON_SRC" --out "$APPICONSET_DIR/icon_16x16.png"      > /dev/null
sips -z 32 32     "$ICON_SRC" --out "$APPICONSET_DIR/icon_16x16@2x.png"   > /dev/null
sips -z 32 32     "$ICON_SRC" --out "$APPICONSET_DIR/icon_32x32.png"      > /dev/null
sips -z 64 64     "$ICON_SRC" --out "$APPICONSET_DIR/icon_32x32@2x.png"   > /dev/null
sips -z 128 128   "$ICON_SRC" --out "$APPICONSET_DIR/icon_128x128.png"    > /dev/null
sips -z 256 256   "$ICON_SRC" --out "$APPICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$ICON_SRC" --out "$APPICONSET_DIR/icon_256x256.png"    > /dev/null
sips -z 512 512   "$ICON_SRC" --out "$APPICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$ICON_SRC" --out "$APPICONSET_DIR/icon_512x512.png"    > /dev/null
sips -z 1024 1024 "$ICON_SRC" --out "$APPICONSET_DIR/icon_512x512@2x.png" > /dev/null

mv "$APPICONSET_DIR" "$ASSET_CATALOG_DIR/"
cat > "$ASSET_CATALOG_DIR/AppIcon.appiconset/Contents.json" <<'EOF'
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
  --compile "$APP/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$PARTIAL_PLIST" \
  "$ASSET_CATALOG_DIR"

rm -rf "$ASSET_ROOT"

# Ad-hoc codesign
codesign --force --sign - --entitlements "$SCRIPT_DIR/entitlements.plist" "$APP"

echo "Built and signed universal Claude Token Meter.app at $APP"
