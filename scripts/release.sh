#!/bin/bash
# Builds MultiCred.app for real use.
#
#   scripts/release.sh            -> dist/MultiCred.app, ad hoc signed, hardened runtime
#
# With a Developer ID (distribution to other Macs), set:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
# and, to notarize, either a stored keychain profile (local use):
#   NOTARY_PROFILE="multicred-notary"   # created once with: xcrun notarytool store-credentials
# or Apple ID credentials (CI):
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD   # app-specific password
# The app is then signed, notarized and stapled. Output in dist/:
#   MultiCred.zip, MultiCred.dmg and SHA256SUMS.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
APP="$DIST/MultiCred.app"

rm -rf "$BUILD" "$DIST"
mkdir -p "$DIST"

echo "==> Testing core"
swift test --package-path "$ROOT/Packages/MultiCredCore" >/dev/null

echo "==> Building Release"
xcodebuild -project "$ROOT/MultiCred.xcodeproj" -scheme MultiCred -configuration Release \
  -derivedDataPath "$BUILD" build >/dev/null
cp -R "$BUILD/Build/Products/Release/MultiCred.app" "$APP"

notarize() {
  local file="$1"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    xcrun notarytool submit "$file" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" --wait
  else
    return 1
  fi
}

NOTARIZED=0
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "==> Signing with $DEVELOPER_ID"
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
  ditto -c -k --keepParent "$APP" "$DIST/MultiCred.zip"
  echo "==> Notarizing"
  if notarize "$DIST/MultiCred.zip"; then
    xcrun stapler staple "$APP"
    NOTARIZED=1
  else
    echo "    No notarization credentials: the app is signed but NOT notarized"
  fi
else
  echo "==> No DEVELOPER_ID: ad hoc signature with hardened runtime (fine on this Mac)"
  codesign --force --deep --options runtime --sign - "$APP"
fi

codesign --verify --strict "$APP"

# Final artifacts are built from the (stapled) app.
rm -f "$DIST/MultiCred.zip"
ditto -c -k --keepParent "$APP" "$DIST/MultiCred.zip"

echo "==> Creating DMG"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MultiCred" -srcfolder "$STAGE" -ov -format UDZO "$DIST/MultiCred.dmg" >/dev/null
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DIST/MultiCred.dmg"
  if [[ "$NOTARIZED" == 1 ]]; then
    notarize "$DIST/MultiCred.dmg"
    xcrun stapler staple "$DIST/MultiCred.dmg"
  fi
fi

(cd "$DIST" && shasum -a 256 MultiCred.zip MultiCred.dmg > SHA256SUMS.txt)

echo "==> Done: $APP"
echo "    notarized: $([[ $NOTARIZED == 1 ]] && echo yes || echo no)"
echo "    Install: move it to /Applications and open it."
