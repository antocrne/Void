#!/bin/zsh
# Builds Void in Release and packages it as build/Void-<version>.dmg
# (Void.app + a shortcut to /Applications, to install by drag and drop).
#   ./scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Void.app"

echo "→ Compilation Release…"
xcodebuild -project Void.xcodeproj -scheme Void -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" build -quiet

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$ROOT/build/Void-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "→ Préparation de l'image disque…"
ditto "$APP" "$STAGING/Void.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Void $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" -quiet

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
