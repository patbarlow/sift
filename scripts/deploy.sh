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
cp .build/debug/Sift Sift.app/Contents/MacOS/Sift
if [ -d .build/debug/Sift_Sift.bundle ]; then
  cp -R .build/debug/Sift_Sift.bundle Sift.app/Contents/Resources/
fi
codesign --force --sign "$IDENTITY" Sift.app
open Sift.app
echo "deployed + signed"
