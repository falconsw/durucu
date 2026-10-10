#!/bin/zsh
# Builds a Developer ID signed, notarized Dürücü and packs it for GitHub Releases / Homebrew.
#
#   NOTARY_PROFILE=<notarytool keychain profile> ./scripts/release.sh
#
# Create the profile once with:
#   xcrun notarytool store-credentials <profile> --apple-id <email> --team-id <TEAM_ID>
# Without NOTARY_PROFILE the app is signed but not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"(.*)".*/\1/')
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')
TEAM_ID=$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
[[ -n "$IDENTITY" ]] || { echo "Developer ID Application sertifikası bulunamadı." >&2; exit 1; }

command -v xcodegen >/dev/null && xcodegen generate --quiet
rm -rf build/release
xcodebuild -project Durucu.xcodeproj -scheme Durucu -configuration Release \
  -derivedDataPath build/release -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp \
  build -quiet

APP=build/release/Build/Products/Release/Durucu.app
codesign --verify --strict --deep "$APP"
mkdir -p dist
ZIP="dist/Durucu-$VERSION.zip"
rm -f "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  spctl --assess --type execute --verbose "$APP"
else
  echo "Uyarı: NOTARY_PROFILE verilmedi, uygulama noter onaysız paketleniyor." >&2
fi

ditto -c -k --keepParent "$APP" "$ZIP"
echo "Paket: $ZIP"
echo "sha256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
