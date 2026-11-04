#!/bin/bash
# Installs the latest Switchboard release:
#   curl -fsSL https://raw.githubusercontent.com/sagarvarma1/monitor/main/install.sh | bash
set -euo pipefail

BASE="https://github.com/sagarvarma1/monitor/releases/latest/download"
TEAM_ID="2NM47V54SX"  # the Apple developer team that signs Switchboard releases
TMP=$(mktemp -d)
MOUNT="$TMP/mount"
cleanup() { hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

echo "Downloading Switchboard..."
curl -fsSL "$BASE/Switchboard.dmg" -o "$TMP/Switchboard.dmg"
curl -fsSL "$BASE/Switchboard.dmg.sha256" -o "$TMP/Switchboard.dmg.sha256"
(cd "$TMP" && shasum -a 256 -c Switchboard.dmg.sha256 >/dev/null) || { echo "Checksum mismatch, not installing." >&2; exit 1; }

mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$TMP/Switchboard.dmg"

# The checksum only proves the download matches the release page; this proves the app is ours, signed and
# notarized by Apple.
APP="$MOUNT/Switchboard.app"
codesign --verify --deep --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" "$APP" \
    || { echo "Switchboard.app isn't signed by the expected developer, not installing." >&2; exit 1; }
spctl --assess --type execute "$APP" 2>/dev/null || { echo "macOS doesn't accept this build as notarized, not installing." >&2; exit 1; }

DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x Switchboard 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST/Switchboard.app"
cp -R "$MOUNT/Switchboard.app" "$DEST/"
open "$DEST/Switchboard.app"
echo "Installed $DEST/Switchboard.app"
