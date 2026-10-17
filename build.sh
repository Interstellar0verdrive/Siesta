#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) Siesta.app into ./build using only the
# Xcode Command Line Tools. Pass --zip to also produce build/Siesta-<version>.zip.
set -e
cd "$(dirname "$0")"
APP="build/Siesta.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
swiftc -O -swift-version 5 -target arm64-apple-macos13  -o build/obj/Siesta-arm64  Sources/main.swift
swiftc -O -swift-version 5 -target x86_64-apple-macos13 -o build/obj/Siesta-x86_64 Sources/main.swift
lipo -create build/obj/Siesta-arm64 build/obj/Siesta-x86_64 -output "$APP/Contents/MacOS/Siesta"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/Siesta.icns Resources/SiestaInactive.png Resources/SiestaInactive@2x.png Resources/SiestaStandby.pdf "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built: $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Siesta"))"
if [[ "$1" == "--zip" ]]; then
  ZIP="build/Siesta-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  (cd build && shasum -a 256 "Siesta-$VERSION.zip" > "Siesta-$VERSION.zip.sha256")
  echo "Packaged: $ZIP (+ .sha256)"
fi
