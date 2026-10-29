#!/bin/bash
# Builds build/Switchboard.app (release, ad-hoc signed).
#   ./build.sh            build
#   ./build.sh --run      build, then (re)launch the app from build/
#   ./build.sh --install  build, copy to /Applications (or ~/Applications), then (re)launch it.
#                         On first launch the app connects itself to Claude Code and adds itself to login items.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Switchboard"

APP=build/Switchboard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Switchboard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

relaunch() {
    pkill -x Switchboard 2>/dev/null && sleep 0.5 || true
    open "$1"
    echo "Launched $1"
}

case "${1:-}" in
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
