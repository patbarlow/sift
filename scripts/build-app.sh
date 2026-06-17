#!/usr/bin/env bash
# Build Sift and bundle it into Sift.app
# Usage: ./scripts/build-app.sh [release|debug]   (default: release)

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
case "$CONFIG" in
    release) FLAG="-c release" ;;
    debug)   FLAG="" ;;
    *) echo "Usage: $0 [release|debug]"; exit 1 ;;
esac

echo "Building ($CONFIG)…"
swift build $FLAG

BIN_DIR=$(swift build $FLAG --show-bin-path)
BIN="$BIN_DIR/Sift"
APP="$PWD/Sift.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Sift"

# SwiftPM emits resources into a `<TargetName>_<Module>.bundle` next to the
# binary. Copy it into the app so `Bundle.module` resolves at runtime.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# Embed Sparkle.framework (auto-updates) and point the binary at it.
if [ -d "$BIN_DIR/Sparkle.framework" ]; then
    cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Sift" 2>/dev/null || true
fi

# App icon: compile the iconset into AppIcon.icns (referenced by Info.plist).
if [ -d Resources/AppIcon.iconset ]; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>Sift</string>
    <key>CFBundleDisplayName</key>      <string>Sift</string>
    <key>CFBundleIdentifier</key>       <string>dev.patbarlow.Sift</string>
    <key>CFBundleVersion</key>          <string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key>       <string>Sift</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>SUFeedURL</key>                <string>https://raw.githubusercontent.com/patbarlow/sift/main/appcast.xml</string>
    <key>SUPublicEDKey</key>            <string>DXaM+fPfK1BV4Q2ZFL72kY2QAEkgduZvo+77jYb5Dnk=</string>
    <key>SUEnableAutomaticChecks</key>  <true/>
    <key>SUScheduledCheckInterval</key> <integer>86400</integer>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.patbarlow.Sift.oauth</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>sift</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "Built $APP"
echo
echo "Run with: open $APP"
echo "Or for log output: $APP/Contents/MacOS/Sift"
