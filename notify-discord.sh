#!/usr/bin/env bash
# notify-discord.sh — Post development events to Discord #acp-updates channel.
# Usage: notify-discord.sh <event> <title> <description> [url] [color]
# Events: branch-created, pr-created, pr-merged, upstream-pr-created, upstream-pr-merged

set -euo pipefail

WEBHOOK_URL="${DISCORD_DEV_WEBHOOK_URL:-}"
# BUG FIX (2026-07-25): this used to point at
# ~/dune-docker-addon/e2e-integration/secrets/dev-webhook-url.txt -- a
# path inside the 15GB redundant scratch directory (~/dune-docker-addon)
# that was deleted during a home-directory cleanup audit, without
# realizing the deployed copy of this script (~/.local/bin/notify-discord.sh,
# the one actually invoked by validate-and-report.sh's $NOTIFY) depended
# on a secret file living inside it. The actual webhook URL value was not
# recoverable from anything left on disk after the deletion --
# notifications have been silently broken (this script fails open with
# exit 0, by design, rather than crashing callers) since.
# Moved the expected path to a stable, non-project location that won't
# be at risk from future repository/workspace cleanups. A new webhook
# URL still needs to be generated and placed at this path (or exported
# as DISCORD_DEV_WEBHOOK_URL) before notifications will resume.
WEBHOOK_FILE="${HOME}/.config/acp-ops-monitor/dev-webhook-url.txt"

if [ -z "$WEBHOOK_URL" ] && [ -f "$WEBHOOK_FILE" ]; then
  WEBHOOK_URL="$(tr -d '\r\n' < "$WEBHOOK_FILE")"
fi

if [ -z "$WEBHOOK_URL" ]; then
  echo "No Discord webhook URL found. Set DISCORD_DEV_WEBHOOK_URL or create $WEBHOOK_FILE" >&2
  exit 0
fi

EVENT="${1:-}"
TITLE="${2:-}"
DESC="${3:-}"
URL="${4:-}"
COLOR="${5:-}"

if [ -z "$EVENT" ] || [ -z "$TITLE" ]; then
  echo "Usage: notify-discord.sh <event> <title> [description] [url] [color]" >&2
  exit 1
fi

# BUG FIX (2026-07-24): this case statement previously *unconditionally*
# overwrote COLOR based on $EVENT, even when the caller passed an explicit
# color argument. Every call site that used the generic "deploy" event
# (validate-and-report.sh's success/resolved/issue notifications) passed a
# distinct color per outcome (green for all-clear, red for issues) — but
# because "deploy" was hardcoded to red in this table, every single one of
# those notifications rendered red in Discord regardless of actual outcome,
# making it impossible to visually distinguish "all clear" from "issues
# found" without opening the message. Fixed by only applying a default
# color here when the caller did NOT pass one explicitly — an explicit
# color argument must always win over the event-name default.
if [ -z "$COLOR" ]; then
  case "$EVENT" in
    branch-created)      COLOR="5814783"  ;; # purple
    pr-created)          COLOR="3447003"  ;; # blue
    pr-merged)           COLOR="3066993"  ;; # green
    upstream-pr-created) COLOR="15105570" ;; # orange
    upstream-pr-merged)  COLOR="3066993"  ;; # green
    deploy)              COLOR="10181046" ;; # red (default only if caller omitted color)
    *)                   COLOR="0"        ;;
  esac
fi

# Convert literal \n in description to actual newlines
DESC=$(printf '%b' "$DESC")

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Voice: these notifications are the Mentat's, not a separate "ACP" bot's. The sender, its avatar and the
# footer are overridable per host (NOTIFY_SENDER_NAME / NOTIFY_AVATAR_URL / NOTIFY_FOOTER_TEXT) and are
# handed to Python through the environment, never interpolated into the program text.
# The hourly job itself is called Projection (a Mentat's forward computation); the manual pipeline events
# (branch/PR created) are not part of that hourly run, so they carry a different footer.
export NOTIFY_SENDER_NAME="${NOTIFY_SENDER_NAME:-Sahir Venn}"
export NOTIFY_AVATAR_URL="${NOTIFY_AVATAR_URL:-https://raw.githubusercontent.com/Project-Arrakis/mentat/main/assets/bot-icon-256.png}"
if [ -z "${NOTIFY_FOOTER_TEXT:-}" ]; then
  case "$EVENT" in
    branch-created|pr-created) NOTIFY_FOOTER_TEXT="Mentat · development pipeline" ;;
    *)                         NOTIFY_FOOTER_TEXT="Projection · the Mentat's hourly computation" ;;
  esac
fi
export NOTIFY_FOOTER_TEXT

PAYLOAD=$(python3 -c "
import json, os, sys
payload = {
    'username': os.environ['NOTIFY_SENDER_NAME'],
    'avatar_url': os.environ['NOTIFY_AVATAR_URL'],
    'embeds': [{
        'title': sys.argv[1],
        'description': sys.argv[2],
        'url': sys.argv[3] if sys.argv[3] else None,
        'color': int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else 0,
        'timestamp': '$TIMESTAMP',
        'footer': {'text': os.environ['NOTIFY_FOOTER_TEXT']}
    }]
}
print(json.dumps(payload))
" "$TITLE" "$DESC" "${URL:-}" "${COLOR:-0}" 2>/dev/null)

if [ -z "$PAYLOAD" ]; then
  echo "Failed to build JSON payload" >&2
  exit 0
fi

curl -fsS -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" >/dev/null 2>&1 || true

echo "Discord notification sent: $EVENT — $TITLE"
