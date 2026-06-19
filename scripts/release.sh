#!/usr/bin/env bash
# Cut a Sift release that existing installs auto-update to via Sparkle.
#
# It builds the app, signs it with your Developer ID (hardened runtime),
# notarizes + staples it with Apple, packages it, signs the archive with your
# Sparkle key, appends an entry to appcast.xml, and publishes a GitHub Release.
#
# One-time setup:
#   1. Developer ID Application cert in your Keychain (set SIFT_SIGN_IDENTITY or
#      put it in scripts/.signing — same as deploy.sh).
#   2. A notarytool keychain profile (uses an app-specific password, stored in
#      the Keychain — never in this repo):
#        xcrun notarytool store-credentials sift-notary \
#          --apple-id "you@example.com" --team-id T544U3WVL6 --password "APP-SPECIFIC-PASSWORD"
#
# Usage: ./scripts/release.sh <version>        e.g. ./scripts/release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: $0 <version>   e.g. $0 0.2.0}"
BUILD="$(git rev-list --count HEAD)"
# Releases must be signed with a Developer ID Application cert (not the
# Apple Development cert deploy.sh uses). Auto-detect it from the Keychain.
IDENTITY="${SIFT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/')}"
NOTARY_PROFILE="${SIFT_NOTARY_PROFILE:-sift-notary}"
REPO="patbarlow/sift"
APP="Sift.app"
ZIP="dist/Sift-$VERSION.zip"
DMG="dist/Sift-$VERSION.dmg"
DL_URL="https://github.com/$REPO/releases/download/v$VERSION/Sift-$VERSION.zip"

case "$IDENTITY" in
    "Developer ID"*) ;;
    *) echo "✗ Need a Developer ID identity to notarize (got: '${IDENTITY:-none}'). Set SIFT_SIGN_IDENTITY."; exit 1 ;;
esac

echo "▶ Building $APP — v$VERSION (build $BUILD)"
./scripts/build-app.sh release
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

echo "▶ Signing with Developer ID (hardened runtime, timestamped)"
FW="$APP/Contents/Frameworks/Sparkle.framework"
# Inside-out: nested helpers first, then the framework, then the app.
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$FW/Versions/B/XPCServices/Installer.xpc" \
    "$FW/Versions/B/XPCServices/Downloader.xpc" \
    "$FW/Versions/B/Updater.app" \
    "$FW/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "  signature OK"

echo "▶ Packaging"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▶ Notarizing (waits for Apple — usually under a minute)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
echo "▶ Stapling the ticket onto the app"
xcrun stapler staple "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip so the ticket ships

echo "▶ Creating DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -srcfolder "$STAGE" -volname "Sift" -format UDZO -fs HFS+ -o "$DMG" -quiet
rm -rf "$STAGE"
# The app inside the DMG is already stapled — Gatekeeper accepts it.
# Stapling the DMG itself requires a separate notarization submission, skip it.

echo "▶ Signing the archive with the Sparkle key"
SIGN_UPDATE="$(find .build/artifacts -name sign_update 2>/dev/null | head -1)"
[ -n "$SIGN_UPDATE" ] || { echo "✗ sign_update not found — run 'swift build' first"; exit 1; }
SIG_ATTRS="$("$SIGN_UPDATE" "$ZIP")"   # -> sparkle:edSignature="…" length="…"

echo "▶ Adding the release to appcast.xml"
PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
cat > dist/item.xml <<ITEM
    <item>
      <title>Sift $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$DL_URL" type="application/octet-stream" $SIG_ATTRS />
    </item>
ITEM
awk '/RELEASES: release.sh inserts/{print; while ((getline line < "dist/item.xml") > 0) print line; next} {print}' \
    appcast.xml > appcast.xml.tmp && mv appcast.xml.tmp appcast.xml
rm -f dist/item.xml

echo "▶ Publishing GitHub Release v$VERSION"
gh release create "v$VERSION" "$DMG" "$ZIP" --repo "$REPO" --title "Sift $VERSION" \
    --notes "Auto-updates via Sparkle." 2>/dev/null \
  || gh release upload "v$VERSION" "$DMG" "$ZIP" --repo "$REPO" --clobber

git add appcast.xml
git commit -q -m "release: v$VERSION"
git push -q origin main

echo "✔ Released v$VERSION — existing installs will pick it up on their next update check."
