#!/bin/bash
# Adds Switchboard hooks to ~/.claude/settings.json.
# Backs the file up first, merges with existing hooks, and is safe to re-run.
#   ./install-hooks.sh [--settings PATH] [--port N]
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
PORT=7777
while [[ $# -gt 0 ]]; do
    case "$1" in
        --settings) SETTINGS="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }

# Events Switchboard listens to. PermissionRequest/PostToolUse/StopFailure go beyond the basic
# six so red appears the moment a prompt shows and clears as soon as you approve.
EVENTS='["SessionStart","UserPromptSubmit","PreToolUse","PermissionRequest","PostToolUse","PostToolUseFailure","Notification","Stop","StopFailure","SessionEnd"]'

# Forward the hook's stdin JSON. $PPID is the Claude Code process (used to find its terminal tab).
# Hard 0.5s cap and "|| true", so a closed or hung app never slows down or breaks Claude Code.
# The trailing marker is how install/uninstall recognise our entries.
CMD='curl -s -o /dev/null --connect-timeout 0.2 -m 0.5 -X POST -H "Content-Type: application/json" -H "X-Claude-PID: $PPID" --data-binary @- http://127.0.0.1:'"$PORT"'/event >/dev/null 2>&1 || true # switchboard'
# PermissionRequest waits (up to ~10 min) for Allow/Deny from the pill and prints it as the hook's decision.
# Claude Code shows its own prompt meanwhile; whichever answer comes first wins.
PERM_CMD='curl -s --connect-timeout 0.2 -m 590 -X POST -H "Content-Type: application/json" -H "X-Claude-PID: $PPID" --data-binary @- http://127.0.0.1:'"$PORT"'/permission 2>/dev/null || true # switchboard'
# A second Stop handler, run in the background (asyncRewake) so the turn ends normally. It waits for a reply typed
# into the pill; if one comes it goes to stderr with exit 2, which wakes Claude with it.
REPLY_CMD='r=$(curl -s --connect-timeout 0.2 -m 7190 -X POST -H "Content-Type: application/json" -H "X-Claude-PID: $PPID" --data-binary @- http://127.0.0.1:'"$PORT"'/reply 2>/dev/null); [ -n "$r" ] && { printf "%s\n" "$r" >&2; exit 2; }; exit 0 # switchboard'

mkdir -p "$(dirname "$SETTINGS")"
[[ -s "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || { echo "$SETTINGS is not valid JSON; not touching it." >&2; exit 1; }

BACKUP="$SETTINGS.switchboard-backup-$(date +%Y%m%d-%H%M%S)"
[[ -e "$BACKUP" ]] && BACKUP="$BACKUP-$$"   # never clobber an earlier backup
cp -p "$SETTINGS" "$BACKUP"
echo "Backed up $SETTINGS -> $BACKUP"

TMP="$(mktemp)"
jq --arg cmd "$CMD" --arg perm "$PERM_CMD" --arg reply "$REPLY_CMD" --argjson events "$EVENTS" '
  def ours: (.command? // "") | test("# switchboard$");
  # Drop any previous Switchboard handlers (so re-running updates them), keep everything else.
  def strip: map(if any(.hooks[]?; ours) then (.hooks |= map(select(ours | not))) | select(.hooks | length > 0) else . end);
  .hooks = (.hooks // {})
  | reduce $events[] as $e (.;
      .hooks[$e] = (((.hooks[$e] // []) | strip) + [{"hooks": (
        if $e == "PermissionRequest" then [{"type": "command", "command": $perm, "timeout": 600}]
        elif $e == "Stop" then [{"type": "command", "command": $cmd, "timeout": 2},
                                {"type": "command", "command": $reply, "timeout": 7200, "asyncRewake": true}]
        else [{"type": "command", "command": $cmd, "timeout": 2}] end)}]))
' "$SETTINGS" > "$TMP"
jq empty "$TMP"
cat "$TMP" > "$SETTINGS"   # write in place to keep permissions and symlinks
rm -f "$TMP"

echo "Installed Switchboard hooks for: $(echo "$EVENTS" | jq -r 'join(", ")')"
echo "Restart running Claude Code sessions (or open /hooks in them) so they pick up the new hooks."
