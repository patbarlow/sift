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

# Universal binary so it runs on both Apple Silicon and Intel Macs.
ARCHS="--arch arm64 --arch x86_64"

echo "Building ($CONFIG, universal)…"
swift build $FLAG $ARCHS

BIN_DIR=$(swift build $FLAG $ARCHS --show-bin-path)
BIN="$BIN_DIR/Sift"
APP="$PWD/Sift.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Sift"

# Bundle the SVG assets straight into Contents/Resources, loaded via Bundle.main.
cp Sources/Sift/Resources/*.svg "$APP/Contents/Resources/"

# Embed Sparkle.framework (auto-updates) and point the binary at it.
if [ -d "$BIN_DIR/Sparkle.framework" ]; then
    cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
    # cp -R creates AppleDouble sidecar files (._*) that break Gatekeeper's
    # seal check — strip them before signing.
    find "$APP/Contents/Frameworks/Sparkle.framework" -name '._*' -delete
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
