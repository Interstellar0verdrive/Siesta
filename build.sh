#!/bin/zsh
# Builds Siesta.app into ./build using only the Xcode Command Line Tools (no Xcode project needed).
set -e
cd "$(dirname "$0")"
APP="build/Siesta.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/Siesta" Sources/main.swift
cp Resources/Info.plist "$APP/Contents/"
cp Resources/Siesta.icns Resources/SiestaInactive.png Resources/SiestaInactive@2x.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built: $APP"
