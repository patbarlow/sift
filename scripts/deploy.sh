#!/bin/bash
# Build, install into Sift.app, re-sign, and relaunch.
#
# Signing matters: macOS permission grants are keyed to the app's code identity.
# Unsigned builds change identity on every compile, which silently revokes TCC
# grants (and Keychain access). A stable signing identity keeps it consistent.
set -euo pipefail
cd "$(dirname "$0")/.."

# Code-signing identity. Set SIFT_SIGN_IDENTITY in your environment, or drop it
# in scripts/.signing (gitignored). Falls back to ad-hoc ("-") signing if unset.
IDENTITY="${SIFT_SIGN_IDENTITY:-$(cat scripts/.signing 2>/dev/null || true)}"
IDENTITY="${IDENTITY:--}"

swift build
osascript -e 'quit app "Sift"' 2>/dev/null || true
sleep 1
mkdir -p Sift.app/Contents/Frameworks Sift.app/Contents/Resources
cp .build/debug/Sift Sift.app/Contents/MacOS/Sift
cp Sources/Sift/Resources/*.svg Sift.app/Contents/Resources/
# Refresh the embedded Sparkle.framework and point the fresh binary at it.
if [ -d .build/debug/Sparkle.framework ]; then
  rm -rf Sift.app/Contents/Frameworks/Sparkle.framework
  cp -R .build/debug/Sparkle.framework Sift.app/Contents/Frameworks/
  install_name_tool -add_rpath "@executable_path/../Frameworks" Sift.app/Contents/MacOS/Sift 2>/dev/null || true
fi
codesign --deep --force --sign "$IDENTITY" Sift.app
open Sift.app
echo "deployed + signed"
