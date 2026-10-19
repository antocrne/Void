#!/bin/zsh
# Publishes the project's version (MARKETING_VERSION) as a GitHub release, from main as it is on GitHub:
#   - build/Void-<version>.zip, that Void installs by itself (bar above the page, Void → Rechercher les
#     mises à jour…), for every version;
#   - build/Void-<version>.dmg, for new installations, only for a version without a third number
#     (0.3, 1.0): 0.2.1, 0.2.2… are only installed from Void.
# Versions before 1.0 are published as pre-releases. Like any build of the Void scheme, the Release
# build also replaces /Applications/Void.app (quitting it first).
#   ./scripts/release.sh notes.md
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
NOTES=${1:?"usage: $0 <notes.md>"}
[[ -f "$NOTES" ]] || { echo "✗ Pas de notes de version à $NOTES"; exit 1; }

[[ $(git branch --show-current) == main ]] || { echo "✗ À lancer depuis main"; exit 1; }
git fetch -q origin main
[[ -z $(git status --porcelain --untracked-files=no) ]] || { echo "✗ Des modifications ne sont pas commitées"; exit 1; }
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "✗ main n'est pas identique à origin/main"; exit 1; }

VERSIONS=($(grep -o 'MARKETING_VERSION = [0-9.]*' Void.xcodeproj/project.pbxproj | awk '{print $3}' | sort -u))
(( ${#VERSIONS} == 1 )) || { echo "✗ MARKETING_VERSION diffère selon les configurations : $VERSIONS"; exit 1; }
VERSION=$VERSIONS[1]
TAG="v$VERSION"
if gh release view "$TAG" > /dev/null 2>&1; then
  echo "✗ $TAG est déjà publiée : passer d'abord à la version suivante (MARKETING_VERSION)"
  exit 1
fi

DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Void.app"
echo "→ Compilation Release de Void $VERSION…"
xcodebuild -project Void.xcodeproj -scheme Void -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" build -quiet
BUILT=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ $BUILT == $VERSION ]] || { echo "✗ L'app compilée est en $BUILT, pas en $VERSION"; exit 1; }
# Void refuses an update that isn't signed by the same team as itself.
codesign --verify --deep --strict "$APP"
# Read whole before searching: `grep -q` stops at the first match, and codesign, still writing,
# then dies of SIGPIPE, which pipefail takes for a failure.
SIGNATURE=$(codesign -dv "$APP" 2>&1)
[[ $SIGNATURE == *$'\n'TeamIdentifier=[A-Z0-9]* ]] || { echo "✗ L'app n'est pas signée par une équipe"; exit 1; }

ZIP="$ROOT/build/Void-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
ASSETS=("$ZIP")
if [[ $VERSION != *.*.* ]]; then
  "$ROOT/scripts/make-dmg.sh" --no-build
  ASSETS+=("$ROOT/build/Void-$VERSION.dmg")
fi

FLAGS=()
[[ $VERSION == 0.* ]] && FLAGS+=(--prerelease)
gh release create "$TAG" "${ASSETS[@]}" --target "$(git rev-parse HEAD)" --title "Void $VERSION" --notes-file "$NOTES" "${FLAGS[@]}"
echo "✓ Void $VERSION publiée : ${ASSETS:t}"
