#!/bin/zsh
# Builds Void in Release and puts it in /Applications, in place of the copy there; quits the app
# first if it is running, and opens the new one.
#   ./scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Void.app"
TARGET="/Applications/Void.app"

echo "→ Compilation Release…"
xcodebuild -project Void.xcodeproj -scheme Void -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" build -quiet

# The scheme's post-action has already copied it; done again here in case it couldn't.
"$ROOT/scripts/copy-to-applications.sh" "$APP"
open "$TARGET"
