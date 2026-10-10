#!/bin/zsh
# Builds a Release copy of Dürücü and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null && xcodegen generate --quiet
xcodebuild -project Durucu.xcodeproj -scheme Durucu -configuration Release \
  -derivedDataPath build -destination 'platform=macOS' build -quiet

APP=build/Build/Products/Release/Durucu.app
TARGET=/Applications/Durucu.app

osascript -e 'quit app id "com.omer.durucu"' 2>/dev/null || true
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"

# Register only the installed copy, so Finder's "Open With" and default handler point at it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in build/Build/Products/*/Durucu.app; do "$LSREGISTER" -u "$copy" 2>/dev/null || true; done
"$LSREGISTER" -f "$TARGET"
/System/Library/CoreServices/pbs -update

echo "Kuruldu: $TARGET"
