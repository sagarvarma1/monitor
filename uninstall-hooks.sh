#!/bin/bash
# Removes Switchboard hooks from ~/.claude/settings.json, leaving all other hooks intact.
#   ./uninstall-hooks.sh [--settings PATH]
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
[[ "${1:-}" == "--settings" ]] && SETTINGS="$2"

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }
[[ -f "$SETTINGS" ]] || { echo "No $SETTINGS; nothing to do."; exit 0; }
jq empty "$SETTINGS" 2>/dev/null || { echo "$SETTINGS is not valid JSON; not touching it." >&2; exit 1; }

BACKUP="$SETTINGS.switchboard-backup-$(date +%Y%m%d-%H%M%S)"
[[ -e "$BACKUP" ]] && BACKUP="$BACKUP-$$"   # never clobber an earlier backup
cp -p "$SETTINGS" "$BACKUP"
echo "Backed up $SETTINGS -> $BACKUP"

TMP="$(mktemp)"
jq '
  def ours: (.command? // "") | test("# switchboard$");
  if .hooks then
    .hooks |= with_entries(
        .value |= map(if any(.hooks[]?; ours) then (.hooks |= map(select(ours | not))) | select(.hooks | length > 0) else . end)
        | select(.value | length > 0))
    | if .hooks == {} then del(.hooks) else . end
  else . end
' "$SETTINGS" > "$TMP"
jq empty "$TMP"
cat "$TMP" > "$SETTINGS"
rm -f "$TMP"
echo "Removed Switchboard hooks."
