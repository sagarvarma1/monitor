#!/bin/bash
# Simulates 5 Claude Code sessions by POSTing hook payloads to Switchboard.
#   scripts/fake-events.sh          set up 5 sessions in mixed states (timers backdated)
#   scripts/fake-events.sh --live   same, then play ~40s of transitions (new red items, approvals, finishes)
#   scripts/fake-events.sh --end    send SessionEnd for all 5 fake sessions
set -euo pipefail

URL="http://127.0.0.1:${SWITCHBOARD_PORT:-7777}/event"
ROOT="${TMPDIR:-/tmp}/switchboard-fake"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
curl -s -m 1 "${URL%/event}/health" >/dev/null || { echo "Switchboard isn't running on ${URL%/event}" >&2; exit 1; }

# name:branch pairs. Real git repos so the panel shows branches.
SESSIONS=(api-server:feature/billing web-frontend:main infra:fix/terraform-drift docs-site:main ml-pipeline:exp/new-tokenizer)
for entry in "${SESSIONS[@]}"; do
    name="${entry%%:*}"; branch="${entry#*:}"
    dir="$ROOT/$name"
    if [[ ! -d "$dir/.git" ]]; then
        mkdir -p "$dir" && git -C "$dir" init -q -b "$branch"
    fi
done

sid() { echo "fake-session-$1"; }

# send NAME EVENT [ago_seconds] [jq-object-of-extra-fields]
send() {
    local name="$1" event="$2" ago="${3:-0}" extra="${4:-{\}}"
    local ts; ts=$(( $(date +%s) - ago ))
    jq -cn --arg sid "$(sid "$name")" --arg cwd "$ROOT/$name" --arg ev "$event" --argjson ts "$ts" --argjson extra "$extra" \
        '{session_id: $sid, cwd: $cwd, hook_event_name: $ev, transcript_path: "/dev/null", permission_mode: "default", switchboard_ts: $ts} + $extra' \
        | curl -s -o /dev/null -m 1 -H "Content-Type: application/json" --data-binary @- "$URL"
    printf '  %-13s %s\n' "$name" "$event"
}

if [[ "${1:-}" == "--end" ]]; then
    for entry in "${SESSIONS[@]}"; do send "${entry%%:*}" SessionEnd 0 '{"reason":"prompt_input_exit"}'; done
    exit 0
fi

echo "Setting up 5 sessions:"
# api-server: blocked on a permission prompt for 4 minutes
send api-server SessionStart 900 '{"source":"startup","model":"claude-opus-5-5"}'
send api-server UserPromptSubmit 600 '{"prompt":"Add Stripe webhook handling for failed payments"}'
send api-server PreToolUse 245 '{"tool_name":"Bash","tool_use_id":"t-api-1","tool_input":{"command":"npm run db:migrate -- --env staging"}}'
send api-server PermissionRequest 240 '{"tool_name":"Bash","tool_use_id":"t-api-1","tool_input":{"command":"npm run db:migrate -- --env staging","description":"Run pending migrations against staging"}}'

# web-frontend: finished its turn 12 minutes ago
send web-frontend UserPromptSubmit 1500 '{"prompt":"Make the settings page responsive"}'
send web-frontend Stop 720 '{"last_assistant_message":"I made the settings page responsive:\n\n- Switched the two-column layout to CSS grid with a single column under 768px\n- Collapsed the sidebar nav into a disclosure menu on mobile\n- Fixed the overflowing API key field\n\nAll 48 component tests pass. Want me to add visual regression snapshots too?"}'

# infra: working
send infra UserPromptSubmit 120 '{"prompt":"Figure out why terraform plan shows drift on the NAT gateway"}'
send infra PreToolUse 5 '{"tool_name":"Bash","tool_use_id":"t-infra-1","tool_input":{"command":"terraform plan -target=aws_nat_gateway.main"}}'

# docs-site: question via AskUserQuestion, 40 seconds ago
send docs-site UserPromptSubmit 300 '{"prompt":"Migrate the docs from Docusaurus to Astro"}'
send docs-site PreToolUse 40 '{"tool_name":"AskUserQuestion","tool_use_id":"t-docs-1","tool_input":{"questions":[{"question":"Should I keep the existing URL structure (/docs/v2/...) or flatten it?","options":[{"label":"Keep URLs (add redirects later)"},{"label":"Flatten and add redirects now"}]}]}}'

# ml-pipeline: finished 2 minutes ago
send ml-pipeline UserPromptSubmit 900 '{"prompt":"Benchmark the new tokenizer against the baseline"}'
send ml-pipeline Stop 130 '{"last_assistant_message":"Benchmark done. New tokenizer: 18% fewer tokens on the eval set, throughput unchanged (±2%). Results are in reports/tokenizer-bench.md."}'

[[ "${1:-}" == "--live" ]] || { echo "Done. Run with --live to see transitions, --end to clear."; exit 0; }

echo "Live transitions (about 40s):"
sleep 5
echo "→ infra hits a permission prompt (new red: notification + pill pulse)"
send infra PermissionRequest 0 '{"tool_name":"Bash","tool_use_id":"t-infra-2","tool_input":{"command":"terraform apply -target=aws_nat_gateway.main -auto-approve"}}'
sleep 6
echo "→ infra's 6s permission Notification arrives (stays red, no duplicate alert)"
send infra Notification 0 '{"message":"Claude needs your permission to use Bash","title":"Permission needed","notification_type":"permission_prompt"}'
sleep 5
echo "→ you approve api-server's migration; it goes green"
send api-server PostToolUse 0 '{"tool_name":"Bash","tool_use_id":"t-api-1","tool_input":{"command":"npm run db:migrate -- --env staging"},"tool_response":{"stdout":"3 migrations applied"}}'
sleep 6
echo "→ api-server finishes; goes yellow"
send api-server Stop 0 '{"last_assistant_message":"Webhook handler added and migrations applied to staging. I added tests for invoice.payment_failed and customer.subscription.deleted."}'
sleep 5
echo "→ you reply to web-frontend; it goes green"
send web-frontend UserPromptSubmit 0 '{"prompt":"Yes, add visual regression snapshots"}'
sleep 5
echo "→ ml-pipeline asks a question via an MCP elicitation notification (new red)"
send ml-pipeline Notification 0 '{"message":"Which GPU queue should the full benchmark run on?","title":"Input needed","notification_type":"elicitation_dialog"}'
sleep 5
echo "→ docs-site session exits (row removed)"
send docs-site SessionEnd 0 '{"reason":"prompt_input_exit"}'
echo "Done."
