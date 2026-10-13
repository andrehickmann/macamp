#!/bin/sh
# Builds a universal release MacAmp.app (ad-hoc signed) and MacAmp.zip into .build/ and prints the app path.
set -e
cd "$(dirname "$0")/.."

arch="--arch arm64 --arch x86_64"
swift build -c release $arch
app=.build/MacAmp.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release $arch --show-bin-path)/MacAmp" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
mkdir -p "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
[ -d Resources/Skins ] && cp -R Resources/Skins "$app/Contents/Resources/"
cp -R Resources/Visualizer "$app/Contents/Resources/"
codesign --force --sign - "$app"
rm -f .build/MacAmp.zip
ditto -c -k --keepParent "$app" .build/MacAmp.zip
echo "$app"
