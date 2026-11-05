#!/bin/bash
# Builds the public Mac app (universal) and packages dist/Switchboard.dmg.
#   scripts/release.sh            sign with a Developer ID certificate if the keychain has one, then notarize
#   scripts/release.sh --unsigned ad-hoc signature, for testing the packaging
# Notarizing reads credentials saved once with:
#   xcrun notarytool store-credentials switchboard --apple-id YOU --team-id 2NM47V54SX --password APP_SPECIFIC_PASSWORD
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 1; }
xcodegen generate --quiet

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)
if [[ "${1:-}" == "--unsigned" ]]; then
    IDENTITY=""
elif [[ -z "$IDENTITY" ]]; then
    echo "No Developer ID Application certificate in the keychain." >&2
    echo "Create one in Xcode > Settings > Accounts > Manage Certificates, or pass --unsigned." >&2
    exit 1
fi

DERIVED=.build/release
rm -rf "$DERIVED/Build/Products" dist
xcodebuild -project Switchboard.xcodeproj -scheme Switchboard -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO -quiet build

mkdir -p dist
APP=dist/Switchboard.app
cp -R "$DERIVED/Build/Products/Release/Switchboard.app" "$APP"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --entitlements Resources/Switchboard.entitlements --sign "$IDENTITY" "$APP"
else
    codesign --force --entitlements Resources/Switchboard.entitlements --sign - "$APP"
fi
codesign --verify --strict "$APP"

# The shipped app must carry exactly the entitlements in Resources/Switchboard.entitlements: nothing like
# get-task-allow (lets other processes attach a debugger) or disable-library-validation (lets it load unsigned code).
SIGNED_ENT=$(mktemp)
codesign -d --entitlements - --xml "$APP" > "$SIGNED_ENT" 2>/dev/null
if ! diff <(plutil -p "$SIGNED_ENT") <(plutil -p Resources/Switchboard.entitlements) >/dev/null; then
    echo "Entitlements differ from Resources/Switchboard.entitlements:" >&2
    plutil -p "$SIGNED_ENT" >&2
    exit 1
fi
rm -f "$SIGNED_ENT"
# Captured first: with pipefail, `grep -q` exiting early would fail codesign's side of the pipe.
SIGNATURE=$(codesign -d -v "$APP" 2>&1)
if [[ -n "$IDENTITY" && "$SIGNATURE" != *"(runtime)"* ]]; then
    echo "The hardened runtime is off." >&2
    exit 1
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG=dist/Switchboard.dmg
hdiutil create -quiet -volname Switchboard -srcfolder "$STAGE" -format UDZO -ov "$DMG"

if [[ -n "$IDENTITY" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile switchboard --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
else
    echo "NOT notarized: Macs that download this DMG in a browser will refuse to open the app." >&2
fi
(cd dist && shasum -a 256 Switchboard.dmg | tee Switchboard.dmg.sha256)
echo "Built $DMG"
