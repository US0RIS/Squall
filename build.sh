#!/bin/bash
# Builds Squall.app into ./build. Requires Xcode or the Command Line Tools (swift 5.9+), macOS 14+.
#
# Squall needs no permissions, so the ad-hoc signature ("-") is fine. To sign with a stable
# identity instead:  SQUALL_SIGN_IDENTITY="Wedge Dev" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Squall"

APP="build/Squall.app"
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Squall"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Every build gets a unique build number. The marketing version (CFBundleShortVersionString)
# is bumped by hand in Resources/Info.plist and recorded in CHANGELOG.md for every revision.
BUILD_NUMBER="$(date +%Y%m%d.%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"

# App icon, drawn by the app's own Logo code.
if "$BIN" --render-iconset build/AppIcon.iconset \
   && iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"; then
    echo "Icon generated"
else
    echo "warning: icon generation failed; building without an icon" >&2
fi

codesign --force --options runtime --sign "${SQUALL_SIGN_IDENTITY:--}" "$APP"
pkill -x Squall 2>/dev/null || true

echo "Built $APP — Squall $VERSION ($BUILD_NUMBER)"
echo "Install:  cp -R \"$APP\" /Applications/ && open /Applications/Squall.app"
