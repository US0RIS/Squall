#!/bin/bash
# Builds Squall and packages it as build/Squall-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Squall.app/Contents/Info.plist)"
STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R build/Squall.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Squall $VERSION" -srcfolder "$STAGE" -ov -format UDZO "build/Squall-$VERSION.dmg"
rm -rf "$STAGE"
echo "Created build/Squall-$VERSION.dmg"
