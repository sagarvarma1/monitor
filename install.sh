#!/bin/bash
# Installs the latest Switchboard release:
#   curl -fsSL https://raw.githubusercontent.com/sagarvarma1/monitor/main/install.sh | bash
set -euo pipefail

BASE="https://github.com/sagarvarma1/monitor/releases/latest/download"
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

DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x Switchboard 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST/Switchboard.app"
cp -R "$MOUNT/Switchboard.app" "$DEST/"
open "$DEST/Switchboard.app"
echo "Installed $DEST/Switchboard.app"
