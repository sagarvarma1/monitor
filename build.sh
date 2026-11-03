#!/bin/bash
# Builds Switchboard from project.yml (via xcodegen) with xcodebuild. Needs no Apple developer account.
#   ./build.sh            build the Mac app into build/
#   ./build.sh --run      build, then (re)launch it from build/
#   ./build.sh --install  build, copy to /Applications (or ~/Applications), then (re)launch it
# scripts/release.sh builds the signed, notarized DMG.
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 1; }
xcodegen generate --quiet  # cheap, and picks up added or removed source files

DERIVED=.build/xcode
MODE="${1:-}"

xcodebuild -project Switchboard.xcodeproj -scheme Switchboard -configuration Release \
    -destination "platform=macOS" -derivedDataPath "$DERIVED" -quiet build

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
    --run) relaunch "$APP" ;;
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
