#!/bin/bash
# Builds Switchboard from project.yml (via xcodegen) with xcodebuild.
#   ./build.sh            build the Mac app (signed for iCloud with your team, Release)
#   ./build.sh --run      build, then (re)launch it from the build folder
#   ./build.sh --install  build, copy to /Applications (or ~/Applications), then (re)launch it
#   ./build.sh --phone    build the iPhone app + Live Activity and install it on the connected iPhone
#   ./build.sh --adhoc    Mac app without signing identity or iCloud (phone features turn themselves off)
# The first signed build needs Xcode signed in to your Apple ID (Xcode > Settings > Accounts); it then creates
# the App IDs, iCloud container and provisioning profiles itself.
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 1; }
[[ Switchboard.xcodeproj/project.pbxproj -nt project.yml ]] || xcodegen generate --quiet

DERIVED=.build/xcode
MODE="${1:-}"

if [[ "$MODE" == "--phone" ]]; then
    xcodebuild -project Switchboard.xcodeproj -scheme SwitchboardMobile -configuration Debug \
        -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet build
    DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available|connected/ {print $3; exit}')
    [[ -n "$DEVICE" ]] || { echo "No iPhone available: connect it (or put it on the same Wi-Fi) and unlock it." >&2; exit 1; }
    xcrun devicectl device install app --device "$DEVICE" "$DERIVED/Build/Products/Debug-iphoneos/Switchboard.app"
    xcrun devicectl device process launch --device "$DEVICE" com.sagarvarma.switchboard.mobile >/dev/null || true
    echo "Installed Switchboard on your iPhone"
    exit 0
fi

SIGNING=(-allowProvisioningUpdates)
if [[ "$MODE" == "--adhoc" ]]; then
    SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= PROVISIONING_PROFILE_SPECIFIER=)
fi
xcodebuild -project Switchboard.xcodeproj -scheme Switchboard -configuration Release \
    -destination "platform=macOS" -derivedDataPath "$DERIVED" "${SIGNING[@]}" -quiet build

APP=build/Switchboard.app
rm -rf "$APP"
mkdir -p build
cp -R "$DERIVED/Build/Products/Release/Switchboard.app" "$APP"
echo "Built $APP"

relaunch() {
    pkill -x Switchboard 2>/dev/null && sleep 0.5 || true
    open "$1"
    echo "Launched $1"
}

case "$MODE" in
    --run|--adhoc) [[ "$MODE" == "--run" ]] && relaunch "$APP" || true ;;
    --install)
        DEST=/Applications
        [[ -w "$DEST" ]] || DEST="$HOME/Applications"
        mkdir -p "$DEST"
        pkill -x Switchboard 2>/dev/null && sleep 0.5 || true
        rm -rf "$DEST/Switchboard.app"
        cp -R "$APP" "$DEST/"
        echo "Installed $DEST/Switchboard.app"
        relaunch "$DEST/Switchboard.app"
        ;;
esac
