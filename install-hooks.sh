#!/bin/bash
# Installs the Claude Code hooks that feed Server Gauge's alerts.
#
# Adds Stop / Notification / UserPromptSubmit hooks to ~/.claude/settings.json
# (merging — existing settings and hooks are preserved; a timestamped backup
# is written first). Safe to re-run: already-installed hooks are skipped.
set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "jq is required (the hooks themselves use it). Install with: brew install jq" >&2
  exit 1
}

S="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$S" ] || echo '{}' > "$S"
jq -e . "$S" > /dev/null || { echo "$S is not valid JSON — fix it first (nothing was changed)." >&2; exit 1; }

cp "$S" "$S.backup-$(date +%Y%m%d%H%M%S)"

# One hook per event: write a small JSON event file for Server Gauge to pick up.
STOP_CMD='d="$HOME/.claude/servergauge-events"; mkdir -p "$d"; f="$d/$(date +%s)-$$-$RANDOM"; jq -c '\''{event:"stop", cwd:(.cwd // ""), session:(.session_id // "")}'\'' > "$f.tmp" && mv "$f.tmp" "$f.json" 2>/dev/null || true'
NOTIF_CMD='d="$HOME/.claude/servergauge-events"; mkdir -p "$d"; f="$d/$(date +%s)-$$-$RANDOM"; jq -c '\''{event:"input", cwd:(.cwd // ""), session:(.session_id // ""), message:(.message // "")}'\'' > "$f.tmp" && mv "$f.tmp" "$f.json" 2>/dev/null || true'
ACK_CMD='d="$HOME/.claude/servergauge-events"; mkdir -p "$d"; f="$d/$(date +%s)-$$-$RANDOM"; jq -c '\''{event:"ack", cwd:(.cwd // ""), session:(.session_id // "")}'\'' > "$f.tmp" && mv "$f.tmp" "$f.json" 2>/dev/null || true'

add_hook() {
  local event="$1" cmd="$2"
  jq --arg ev "$event" --arg cmd "$cmd" '
    .hooks //= {} |
    .hooks[$ev] //= [] |
    if ([.hooks[$ev][]?.hooks[]?.command] | index($cmd)) != null then .
    else .hooks[$ev] += [{hooks: [{type: "command", command: $cmd, async: true}]}]
    end
  ' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
  echo "  ✓ $event"
}

echo "Installing Server Gauge hooks into $S"
add_hook Stop "$STOP_CMD"
add_hook Notification "$NOTIF_CMD"
add_hook UserPromptSubmit "$ACK_CMD"

echo "Done. Restart any open Claude Code sessions to pick the hooks up."
echo "(Backup of your previous settings saved next to settings.json.)"
