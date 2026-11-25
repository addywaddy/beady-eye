#!/bin/zsh
# Builds, signs, notarizes and packages Beady Eye as dist/BeadyEye-<version>.dmg.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your keychain (security find-identity -v -p codesigning).
#   2. Notarization credentials in the keychain (an app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials couchpad-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#
# Usage:  VERSION=0.1.0 Scripts/release.sh
# Override NOTARY_PROFILE or SIGN_IDENTITY if yours differ. NOTARIZE=0 skips Apple's servers (a dry run).
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION=${VERSION:?Set VERSION, for example VERSION=0.1.0}
SIGN_IDENTITY=${SIGN_IDENTITY:-Developer ID Application}
NOTARY_PROFILE=${NOTARY_PROFILE:-couchpad-notary}
NOTARIZE=${NOTARIZE:-1}
export SIGN_IDENTITY
APP=build/BeadyEye.app
DMG=dist/BeadyEye-$VERSION.dmg

echo "==> Building $VERSION"
Scripts/bundle.sh release
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$NOTARIZE" = 1 ]; then
  echo "==> Notarizing the app"
  ditto -c -k --keepParent "$APP" build/BeadyEye.zip
  xcrun notarytool submit build/BeadyEye.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

echo "==> Packaging $DMG"
mkdir -p dist; rm -f "$DMG"
STAGE=build/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Beady Eye" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ "$NOTARIZE" = 1 ]; then
  echo "==> Notarizing the disk image"
  codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi
echo "Built $DMG"
