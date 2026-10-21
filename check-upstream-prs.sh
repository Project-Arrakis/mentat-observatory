#!/usr/bin/env bash
# check-upstream-prs.sh — Track all yacketrj upstream PRs across both repos,
# plus real upstream release tags on repos this fork tracks/syncs from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ci-health.sh"
# shellcheck source=lib/timeouts.sh
source "$SCRIPT_DIR/lib/timeouts.sh"

# Pre-flight: verify GitHub authentication
if ! gh auth status >/dev/null 2>&1; then
  echo "FATAL: gh not authenticated. Set GH_TOKEN." >&2
  exit 1
fi

# Only notifies Discord on PR merge events and on newly-detected upstream
# release tags. Logs status locally.
#
# Usage: bash check-upstream-prs.sh
#
# Release-tag detection (added 2026-07-25): this script previously had no
# visibility into real upstream (Red-Blink) cutting a new release -- it
# only ever watched PR open/merge events on repos this account has PRs
# against. That gap meant a real upstream release (v1.3.65, published
# 2026-07-24) went completely undetected by this hourly monitor, and was
# only discovered manually, well after the fact, during unrelated incident
# response work. check_upstream_release() below closes that gap using the
# same state-cache-diff + Discord-notify-on-transition pattern already
# used for PR merges in check_repo(), so a human doesn't need to
# separately remember to poll `timeout 60 gh release list` on any tracked upstream.

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
NOTIFY="${HOME}/.local/bin/notify-discord.sh"
CACHE="${HOME}/.cache/acp-pr-states.json"
RELEASE_CACHE="${HOME}/.cache/acp-upstream-release-states.json"
ISSUES=0

echo "=== Upstream PR Status ($(date +%H:%M)) ==="

mkdir -p "$(dirname "$CACHE")"
[ -f "$CACHE" ] && OLD_STATE_JSON="$(cat "$CACHE")" || OLD_STATE_JSON="{}"

# REFACTOR (2026-07-24): the original version called `python3 -c` once PER
# PR to read from OLD_STATE_JSON and once PER PR to merge into NEW_STATE_JSON
# — O(n) subprocess spawns for what should be O(1) reads/writes. Refactored
# to: (1) do a single python3 call up front to flatten OLD_STATE_JSON into a
# bash associative array for O(1) in-process lookups, and (2) accumulate new
# state entries into a second associative array, serialized to JSON with a
# single python3 call at the very end. This is both faster (fewer process
# spawns under `set -e` + subshell overhead) and more robust (no risk of a
# mid-loop python3 failure silently dropping a state update via the `||
# echo "$NEW_STATE"` fallback the old version relied on).
declare -A OLD_STATE
while IFS=$'\t' read -r key val; do
  [ -z "$key" ] && continue
  OLD_STATE["$key"]="$val"
done < <(python3 -c "
import json, sys
d = json.loads(sys.argv[1]) if sys.argv[1] else {}
for k, v in d.items():
    print(f'{k}\t{v}')
" "$OLD_STATE_JSON" 2>/dev/null || true)

declare -A NEW_STATE

check_repo() {
  local repo="$1" label="$2"
  echo "--- $label ($repo) ---"

  # Open PRs — just list, no notification
  while IFS=$'\t' read -r pr title url; do
    [ -z "$pr" ] && continue
    local key="${repo}_${pr}"
    echo -e "  PR #$pr: ${YELLOW}OPEN${NC}  ${title:0:80}"
    NEW_STATE["$key"]="OPEN"
  done < <(timeout 60 gh pr list --repo "$repo" --author yacketrj --state open --json number,title,url --jq '.[] | "\(.number)\t\(.title)\t\(.url)"' 2>/dev/null || true)

  # Recently merged — notify Discord on OPEN→MERGED transition
  while IFS=$'\t' read -r pr title url merged; do
    [ -z "$pr" ] && continue
    local key="${repo}_${pr}"
    local old_val="${OLD_STATE[$key]:-UNKNOWN}"
    if [ "$old_val" = "OPEN" ]; then
      echo -e "  PR #$pr: ${GREEN}MERGED${NC} ($merged) ${title:0:60}"
      if [ -x "$NOTIFY" ]; then
        bash "$NOTIFY" upstream-pr-merged \
          "✅ $label PR #$pr Merged!" \
          "**Title:** $title
**Repo:** $repo
**Merged:** $merged" \
          "$url" >/dev/null 2>&1 || true
      fi
    fi
    NEW_STATE["$key"]="MERGED"
  done < <(timeout 60 gh pr list --repo "$repo" --author yacketrj --state merged --limit 5 --json number,title,url,mergedAt --jq '.[] | "\(.number)\t\(.title)\t\(.url)\t\(.mergedAt)"' 2>/dev/null || true)
}

# Check the latest real release tag on a repo this fork tracks/syncs
# from, and notify Discord exactly once when a genuinely new tag first
# appears (never on every run, and never retroactively for a tag that was
# already the latest the first time this check ran against this repo --
# that would either spam on every single hourly run forever, or fire a
# false "new release" notification the very first time this function is
# deployed against a repo that already has releases). Uses the same
# read-old-state / diff / write-new-state pattern as check_repo()'s PR
# merge detection above, just keyed by repo+latest-tag instead of
# repo+PR-number+status.
NEW_RELEASE_STATE="{}"
check_upstream_release() {
  local repo="$1" label="$2"
  local latest_tag latest_url latest_published old_tag

  [ -f "$RELEASE_CACHE" ] && OLD_RELEASE_STATE="$(cat "$RELEASE_CACHE")" || OLD_RELEASE_STATE="{}"

  latest_tag="$(timeout 60 gh release list --repo "$repo" --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
  if [ -z "$latest_tag" ]; then
    echo -e "  ${YELLOW}SKIP:${NC} $label — no releases found"
    return
  fi

  latest_url="https://github.com/${repo}/releases/tag/${latest_tag}"
  latest_published="$(timeout 60 gh release view "$latest_tag" --repo "$repo" --json publishedAt --jq '.publishedAt' 2>/dev/null || echo "unknown")"

  old_tag="$(echo "$OLD_RELEASE_STATE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$repo',''))" 2>/dev/null || echo "")"

  if [ -z "$old_tag" ]; then
    # First time this check has ever run against this repo -- record the
    # current latest tag as the baseline, but do NOT notify. Every real
    # release that existed before this monitor was deployed is not "new."
    echo -e "  ${GREEN}OK:${NC} $label — baseline recorded: $latest_tag (no notification, first run for this repo)"
  elif [ "$old_tag" != "$latest_tag" ]; then
    echo -e "  ${GREEN}NEW RELEASE:${NC} $label — $old_tag -> $latest_tag ($latest_published)"
    if [ -x "$NOTIFY" ]; then
      bash "$NOTIFY" upstream-pr-merged \
        "🚀 $label released $latest_tag" \
        "**Repo:** $repo
**Previous latest:** $old_tag
**New latest:** $latest_tag
**Published:** $latest_published" \
        "$latest_url" >/dev/null 2>&1 || true
    fi
  else
    echo -e "  ${GREEN}OK:${NC} $label — latest release unchanged: $latest_tag"
  fi

  NEW_RELEASE_STATE=$(echo "$NEW_RELEASE_STATE" | python3 -c "import json,sys; d=json.load(sys.stdin); d['$repo']='$latest_tag'; print(json.dumps(d))" 2>/dev/null || echo "$NEW_RELEASE_STATE")
}

check_repo "Red-Blink/dune-awakening-selfhost-docker" "Core"
check_repo "Red-Blink/dune-docker-addons" "Catalog"
echo
check_repo "Project-Arrakis/dune-ops-observability-addon" "Addon"
check_repo "Project-Arrakis/mentat" "Mentat"
check_repo "Project-Arrakis/mentat-link" "Mentat-Link"

echo ""
echo "--- Upstream Release Status ---"
# Only real upstream repos this fork actually tracks/syncs from -- yacketrj's
# own repos (Addon, ACP, Landing) are not forks of anything and have no
# "upstream release" concept distinct from their own releases, which
# check_repo's PR-merge tracking already covers.
check_upstream_release "Red-Blink/dune-awakening-selfhost-docker" "Core upstream"
check_upstream_release "Red-Blink/dune-docker-addons" "Catalog upstream"

echo ""
echo "--- CI Status ---"
check_ci_health "Red-Blink/dune-awakening-selfhost-docker" "Core" || true
check_ci_health "Project-Arrakis/dune-ops-observability-addon" "Addon" || true
check_ci_health "Project-Arrakis/dune-docker-addons" "Catalog" || true
check_ci_health "Project-Arrakis/mentat" "Mentat" || true
check_ci_health "Project-Arrakis/mentat-link" "Mentat-Link" || true

# BUG FIX (2026-07-25): NEW_STATE is a bash associative array
# (declare -A), not a scalar string -- `echo "$NEW_STATE"` under
# `set -u` throws "NEW_STATE: unbound variable" (bash treats bare
# array expansion without an index as referencing the unset [0]
# element in this context) and would have written the literal word
# "NEW_STATE" to the cache file even if it hadn't errored. Serialize it
# to JSON (tab-separated key/value pairs piped to python3, mirroring
# how OLD_STATE_JSON is parsed back into OLD_STATE above) instead of
# trying to echo the array directly.
NEW_STATE_JSON="$(
  {
    for key in "${!NEW_STATE[@]}"; do
      printf '%s\t%s\n' "$key" "${NEW_STATE[$key]}"
    done
  } | python3 -c "
import sys, json
d = {}
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        continue
    k, _, v = line.partition('\t')
    d[k] = v
print(json.dumps(d))
"
)"
echo "$NEW_STATE_JSON" > "$CACHE"
echo "$NEW_RELEASE_STATE" > "$RELEASE_CACHE"

if [ "$ISSUES" -gt 0 ]; then
  echo ""
  echo -e "${RED}$ISSUES CI issue(s) found${NC}"
  exit 1
fi

echo ""
echo -e "${GREEN}All checks passed${NC}"
