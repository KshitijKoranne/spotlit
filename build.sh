#!/bin/sh
# Generates the Xcode project, builds a local test copy (ad-hoc signed) and opens it.
# For the App Store and for testing purchases: open Spotlit.xcodeproj in Xcode and press ⌘R.
set -e
cd "$(dirname "$0")"
xcodegen generate --quiet
xcodebuild -project Spotlit.xcodeproj -scheme Spotlit -configuration Debug -derivedDataPath .build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet build
pkill -x Spotlit || true
rm -rf build && mkdir build && cp -R .build/Build/Products/Debug/Spotlit.app build/
open build/Spotlit.app
echo "Spotlit is running. Look for the icon in the menu bar."
