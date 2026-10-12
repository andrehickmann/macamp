#!/bin/sh
# Builds a release MacAmp.app (ad-hoc signed) into .build/ and prints its path.
set -e
cd "$(dirname "$0")/.."

swift build -c release
app=.build/MacAmp.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/MacAmp "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
codesign --force --sign - "$app"
echo "$app"
