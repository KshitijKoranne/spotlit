#!/bin/sh
# Builds Spotlit.app into ./build and opens it.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Spotlit.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Spotlit "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
pkill -x Spotlit || true
open "$APP"
echo "Spotlit is running. Look for the icon in the menu bar."
