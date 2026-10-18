#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) Siesta.app into ./build using only the
# Xcode Command Line Tools. Pass --zip to also produce build/Siesta-<version>.zip (+ .sha256).
#
# App icon: Resources/Siesta.icns is always bundled (macOS 13–15 and any build without Xcode).
# When the full Xcode asset compiler (actool) is available, Resources/AppIcon.icon — the Icon
# Composer package with the light and dark artwork — is compiled too, so macOS 26 and later
# show the dark variant in Dark appearance.
set -e
cd "$(dirname "$0")"
APP="build/Siesta.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
swiftc -O -swift-version 5 -target arm64-apple-macos13  -framework IOKit -o build/obj/Siesta-arm64  Sources/main.swift
swiftc -O -swift-version 5 -target x86_64-apple-macos13 -framework IOKit -o build/obj/Siesta-x86_64 Sources/main.swift
lipo -create build/obj/Siesta-arm64 build/obj/Siesta-x86_64 -output "$APP/Contents/MacOS/Siesta"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/Siesta.icns Resources/states/*.png Resources/dialog/Siesta-light-512.png Resources/dialog/Siesta-dark-512.png "$APP/Contents/Resources/"
ICON="icns only"
ACTOOL=$(xcrun --find actool 2>/dev/null || true)
# the Command Line Tools have no actool: look inside Xcode.app directly
[[ -z "$ACTOOL" && -x /Applications/Xcode.app/Contents/Developer/usr/bin/actool ]] && ACTOOL=/Applications/Xcode.app/Contents/Developer/usr/bin/actool
if [[ -n "$ACTOOL" ]]; then
  rm -rf build/obj/icon && mkdir -p build/obj/icon
  if "$ACTOOL" Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
       --platform macosx --minimum-deployment-target 13.0 \
       --app-icon AppIcon --include-all-app-icons \
       --output-partial-info-plist build/obj/icon/partial.plist >/dev/null 2>build/obj/icon/actool.log; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIconName AppIcon' "$APP/Contents/Info.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$APP/Contents/Info.plist"
    ICON="icns + Icon Composer package"
  else
    ICON="icns only (actool failed, see build/obj/icon/actool.log)"
  fi
fi
codesign --force --sign - "$APP"
echo "Built: $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Siesta"), icon: $ICON)"
if [[ "$1" == "--zip" ]]; then
  ZIP="build/Siesta-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  (cd build && shasum -a 256 "Siesta-$VERSION.zip" > "Siesta-$VERSION.zip.sha256")
  echo "Packaged: $ZIP (+ .sha256)"
fi
