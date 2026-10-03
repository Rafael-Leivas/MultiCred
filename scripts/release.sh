#!/bin/bash
# Builds MultiCred.app for real use.
#
#   scripts/release.sh            -> dist/MultiCred.app, ad hoc signed, hardened runtime
#
# With a Developer ID (distribution to other Macs), set:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="multicred-notary"   # created once with: xcrun notarytool store-credentials
# and the app is signed, notarized and stapled, and dist/MultiCred.zip is created.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
APP="$DIST/MultiCred.app"

rm -rf "$BUILD" "$APP"
mkdir -p "$DIST"

echo "==> Testing core"
swift test --package-path "$ROOT/Packages/MultiCredCore" >/dev/null

echo "==> Building Release"
xcodebuild -project "$ROOT/MultiCred.xcodeproj" -scheme MultiCred -configuration Release \
  -derivedDataPath "$BUILD" build >/dev/null
cp -R "$BUILD/Build/Products/Release/MultiCred.app" "$APP"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "==> Signing with $DEVELOPER_ID"
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  ditto -c -k --keepParent "$APP" "$DIST/MultiCred.zip"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$DIST/MultiCred.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$DIST/MultiCred.zip"
    ditto -c -k --keepParent "$APP" "$DIST/MultiCred.zip"
  fi
else
  echo "==> No DEVELOPER_ID: ad hoc signature with hardened runtime (fine on this Mac)"
  codesign --force --deep --options runtime --sign - "$APP"
fi

codesign --verify --strict "$APP"
echo "==> Done: $APP"
echo "    Install: move it to /Applications and open it."
