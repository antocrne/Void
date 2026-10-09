#!/bin/zsh
# Puts a built Void.app in /Applications, in place of the copy there. If that copy is running, it is
# quit first (politely, so the session is saved) and not reopened; if it doesn't quit (a dialog
# waiting for an answer), nothing is replaced.
# Called after every build of the Void scheme (Xcode or xcodebuild), and by install.sh.
#   ./scripts/copy-to-applications.sh "<path>/Void.app"
set -euo pipefail

APP=${1:?"usage: $0 <path>/Void.app"}
TARGET="/Applications/Void.app"
RUNNING="$TARGET/Contents/MacOS/Void"

[[ -d "$APP" ]] || { echo "Pas d'app à $APP"; exit 1; }
[[ "$APP" -ef "$TARGET" ]] && exit 0

if pgrep -f "$RUNNING" > /dev/null; then
  echo "→ Fermeture de la copie de /Applications…"
  osascript -e "tell application \"$TARGET\" to quit" || true
  for _ in {1..100}; do
    pgrep -f "$RUNNING" > /dev/null || break
    sleep 0.1
  done
  if pgrep -f "$RUNNING" > /dev/null; then
    echo "✗ La copie de /Applications tourne encore (un dialogue attend ?) : rien n'est remplacé."
    exit 1
  fi
fi

echo "→ Copie dans /Applications…"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
echo "✓ $TARGET ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TARGET/Contents/Info.plist"), $(date '+%H:%M:%S'))"
