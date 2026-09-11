#!/usr/bin/env bash
# validate-and-report.sh — Hourly fork sync, PR rebase, mergeability, and CI validation.
# Auto-syncs core fork main with upstream, rebases open PR branches, and reports issues to Discord.
# Pre-flight: verify GitHub authentication
if ! gh auth status >/dev/null 2>&1; then
  echo "FATAL: gh not authenticated. Set GH_TOKEN." >&2
  exit 1
fi

#
# Usage: bash validate-and-report.sh

set -euo pipefail

# BUG FIX (2026-07-25): sync_decision() (used below to safely gate the
# fork-sync fast-forward) was extracted into lib/sync-direction.sh with
# real unit test coverage, but this script never actually sourced that
# file -- every invocation failed immediately with
# "sync_decision: command not found" the moment it reached the first
# call site. Found while rebasing an unrelated path-fix commit onto
# this change and running the script to verify.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sync-direction.sh
source "$SCRIPT_DIR/lib/sync-direction.sh"
# shellcheck source=lib/ci-health.sh
source "$SCRIPT_DIR/lib/ci-health.sh"

NOTIFY="${HOME}/.local/bin/notify-discord.sh"
# BUG FIX (2026-08-15): this repo moved AGAIN, from the original WSL box
# (Tabr-Tau, decommissioned) to the current host (DA-1), and this
# hardcoded default was never updated -- meaning this entire script has
# aborted immediately at the first `cd "$CORE_DIR"` below on every run
# since that move (there was no crontab installed on DA-1 at all either,
# compounding the gap -- see Arrakis-Project#24). ACP_CORE_DIR/
# ACP_CATALOG_DIR env-var overrides (already supported by install.sh)
# let an operator point this at wherever their real clones live without
# editing this file again the next time a host changes; the defaults
# below are just this account's current, real path on DA-1, not a
# portable assumption.
CORE_DIR="${ACP_CORE_DIR:-${HOME}/projects/repos/dune-awakening-selfhost-docker}"
CATALOG_DIR="${ACP_CATALOG_DIR:-${HOME}/projects/repos/dune-docker-addons}"
TODAY="$(date +%Y-%m-%d)"
ISSUES=0
ACTIVITY=0
REPORT=""
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "=== ACP Validation ($(date +%H:%M)) ==="

# ─── 0. Upstream release detection ───
echo "--- 0. Upstream release detection ---"
cd "$CORE_DIR"

git fetch upstream --tags --quiet 2>/dev/null || true
git fetch origin --quiet 2>/dev/null || true

# Detect new version tags
LATEST_TAG=$(git tag --sort=-creatordate 2>/dev/null | grep -E '^v[0-9]' | head -1)
# BUG FIX (2026-08-15): hardcoded to the old WSL box's real username
# (darkdante) -- this account runs as root on the current host (DA-1).
# check-upstream-prs.sh already uses ${HOME}/.cache/... correctly
# throughout; this file's own state-file paths hadn't been updated to
# match after the host move. See Arrakis-Project#24.
TAG_STATE_FILE="${HOME}/.cache/acp-ops-monitor/known-tags.txt"
mkdir -p "$(dirname "$TAG_STATE_FILE")"
touch "$TAG_STATE_FILE"

if [ -n "$LATEST_TAG" ]; then
  TAG_DATE=$(git log -1 --format=%ai "$LATEST_TAG" 2>/dev/null | cut -d' ' -f1)
  if ! grep -q "^$LATEST_TAG$" "$TAG_STATE_FILE" 2>/dev/null; then
    BEHIND_COUNT=$(git rev-list HEAD.."$LATEST_TAG" --count 2>/dev/null || echo "?")
    echo -e "  ${YELLOW}NEW RELEASE:${NC} $LATEST_TAG ($TAG_DATE) — $BEHIND_COUNT commits behind"
    # File a tracking issue
    FINGERPRINT="release-${LATEST_TAG}"
    COMMIT_LIST=$(git log --oneline HEAD.."$LATEST_TAG" 2>/dev/null | head -10 || echo "unknown")
    timeout 30 gh issue create --title "upstream: $LATEST_TAG released — $BEHIND_COUNT commits ahead" \
      --label "enhancement,severity:high" \
      --body "Upstream released **$LATEST_TAG** on $TAG_DATE.

\`\`\`
$COMMIT_LIST
\`\`\`

Action needed: sync fork main, rebase open PRs, verify CI." \
      --repo Project-Arrakis/dune-awakening-selfhost-docker 2>/dev/null
    echo "$LATEST_TAG" >> "$TAG_STATE_FILE"
    REPORT="${REPORT}\n🆕 **$LATEST_TAG** released ($BEHIND_COUNT commits behind)"
    ACTIVITY=$((ACTIVITY + 1))
  else
    echo -e "  ${GREEN}OK:${NC} $LATEST_TAG already known"
  fi
fi

# ─── 1. Core fork: sync main with upstream ───
echo "--- 1. Core fork sync ---"
cd "$CORE_DIR"

git fetch upstream main --quiet 2>/dev/null || true
git fetch origin --quiet 2>/dev/null || true

UPSTREAM=$(git rev-parse upstream/main)

# BUG FIX (2026-07-23): the original unconditional
# `if [ "$UPSTREAM" != "$ORIGIN_MAIN" ]` below does not check *direction* —
# it fires identically whether origin/main is genuinely behind upstream, OR
# origin/main is AHEAD (has fork-local merged work upstream doesn't have
# yet), OR the two have diverged. Combined with the unconditional
# `git reset --hard upstream/main` + force-push a few lines down, this
# silently destroyed three merged PRs on this fork's main in a single day
# (#103, #104, #108) — each time a PR merged into origin/main, the very
# next hourly run saw a SHA mismatch and reset origin/main straight back to
# upstream/main, discarding the merge with no warning. Fast-forwarding a
# genuinely-behind fork is safe; resetting an ahead-or-diverged fork is
# not. Only treat this as a sync-needed case when upstream/main is NOT
# already reachable from origin/main's history AND origin/main has no
# commits of its own that upstream/main lacks (i.e. origin/main is a pure
# ancestor of upstream/main — the fork is strictly, only behind).
#
# BUG FIX (2026-07-25): the AHEAD_OF_UPSTREAM=0 guard above is necessary
# but not sufficient. It only asks "is origin/main ahead of upstream/main
# *right now*" -- but the actual destructive operation on the next line
# was `git reset --hard upstream/main`, which throws away any commit on
# origin/main that ISN'T reachable from upstream/main, REGARDLESS of
# whether the guard's snapshot-in-time check happened to read AHEAD=0.
# This fork now permanently carries real, fork-only history (incident
# reports, PR merges that will never be upstreamed, etc.) on every real
# commit going forward -- there is no longer a safe moment to blindly
# reset this repo's main to a third-party ref, only a safe moment to
# FAST-FORWARD it. Confirmed via reflog forensics on 2026-07-25 that this
# exact reset call (or a manual reproduction of the same command pattern)
# did in fact wipe a local checkout of main back to upstream/main's raw
# tip, discarding 26 real, already-pushed fork commits from the local
# working copy (origin/main on GitHub was thankfully unaffected, since
# the destructive command ran before this fix, on a checkout that hadn't
# been re-pushed yet -- but the force-push on the very next line would
# have made that loss permanent and remote if it had run one line later).
# Replaced `git reset --hard upstream/main` with `git merge --ff-only
# upstream/main`: identical outcome when genuinely, purely behind (the
# only case this guard is meant to allow), but merge --ff-only REFUSES to
# run at all the instant local history has diverged even slightly --
# it fails loudly and non-destructively instead of silently discarding
# commits, which is the correct failure mode for an unattended hourly
# cron job touching a repo's main branch.
AHEAD_OF_UPSTREAM=$(git rev-list upstream/main..origin/main --count 2>/dev/null || echo "0")
BEHIND=$(git rev-list origin/main..upstream/main --count 2>/dev/null || echo "0")
SYNC_STATUS="$(sync_decision "$AHEAD_OF_UPSTREAM" "$BEHIND")"

if [ "$SYNC_STATUS" = "sync" ]; then
  echo "  SYNC: core fork $BEHIND commits behind — syncing main..."

  # Save current branch and working tree
  CURRENT_BRANCH=$(git branch --show-current)
  STASHED=false
  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    git stash -u -m "auto-sync-${TODAY}" 2>/dev/null && STASHED=true
  fi

  # Sync main with upstream -- fast-forward only, never reset --hard (see
  # 2026-07-25 fix note above). If this fails, main has real local history
  # upstream doesn't have and this sync is correctly aborted rather than
  # destroying it.
  git checkout main 2>/dev/null || git checkout -b main upstream/main
  if git merge --ff-only upstream/main 2>/dev/null; then
    # BUG FIX (2026-07-25): --no-verify removed. This is the actual sync
    # of this fork's real, permanent main branch -- exactly the kind of
    # consequential push this project's own security-first standard
    # (real gate suite: ggshield, gitleaks, trivy, semgrep, npm audit,
    # artifact-guard, web build) is applied to everywhere else, including
    # every manual push made this session. A merge --ff-only can only
    # ever fast-forward main to a real, already-published upstream
    # commit -- it can't introduce anything the gate would have a
    # legitimate reason to block that upstream's own CI didn't already
    # accept -- but running the gate anyway costs little and catches the
    # case where this fork's own environment (not upstream's) has a
    # problem (e.g. a locally-modified dependency, a stale lockfile).
    # PIPESTATUS captured explicitly so a real gate failure is detected
    # rather than swallowed by the `tail` pipe.
    PUSH_OUT="$(git push origin main 2>&1)"
    PUSH_RC="${PIPESTATUS[0]:-$?}"
    echo "$PUSH_OUT" | tail -3
    if [ "$PUSH_RC" -eq 0 ]; then
      echo -e "  ${GREEN}OK:${NC} main synced with upstream ($(echo $UPSTREAM | cut -c1-7))"
    else
      echo -e "  ${RED}PUSH BLOCKED (gate failure):${NC} main was fast-forwarded locally but the push was blocked — investigate manually, local and origin/main are now out of sync"
      REPORT="${REPORT}\n❌ Core fork main push blocked by pre-push gate after fast-forwarding to upstream — local/origin now diverge, needs manual attention"
      ISSUES=$((ISSUES + 1))
    fi
  else
    echo -e "  ${RED}ABORTED:${NC} main has local history that would be lost by a fast-forward — not syncing. Investigate manually."
    REPORT="${REPORT}\n❌ Core fork main could not be fast-forwarded to upstream (local-only history present) — manual sync needed"
    ISSUES=$((ISSUES + 1))
  fi

  # ─── Sync integration/discord with upstream/main using merge ───
  echo -n "  integration/discord: "
  if git show-ref --verify --quiet "refs/remotes/origin/integration/discord" || git show-ref --verify --quiet "refs/heads/integration/discord"; then
    git checkout integration/discord 2>/dev/null || true
    if git merge upstream/main --no-edit 2>/dev/null; then
      # BUG FIX (2026-07-25): --no-verify here silently skipped the real
      # security/quality gate suite (ggshield, gitleaks, trivy, semgrep,
      # npm audit, artifact-guard, web build) on every automated push this
      # unattended hourly cron job makes -- an inconsistent, unreported
      # weakening of the same standard applied everywhere else in this
      # project. The gate script is fully non-interactive and
      # deterministic (verified: no prompts, clean pass/fail exit codes),
      # so there is no hang risk from running it unattended. If the gate
      # genuinely fails after a rebase/merge (e.g. a real test regression
      # introduced upstream), that should be reported as a real issue for
      # a human to look at, not silently bypassed.
      # Piping through `tail` would otherwise swallow git push's real exit
      # code (the pipeline's status becomes tail's, which is always 0) --
      # capture PIPESTATUS explicitly so a gate failure is actually
      # detected instead of always reporting success.
      PUSH_OUT="$(git push origin integration/discord --force-with-lease 2>&1)"
      PUSH_RC="${PIPESTATUS[0]:-$?}"
      echo "$PUSH_OUT" | tail -3
      if [ "$PUSH_RC" -eq 0 ]; then
        echo -e "${GREEN}merged${NC}"
      else
        echo -e "${RED}PUSH BLOCKED (gate failure)${NC}"
        REPORT="${REPORT}\n❌ integration/discord push blocked by pre-push gate after merging upstream/main — investigate manually"
        ISSUES=$((ISSUES + 1))
      fi
    else
      git merge --abort 2>/dev/null || true
      echo -e "${RED}CONFLICT${NC}"
      REPORT="${REPORT}\n❌ integration/discord has merge conflicts with upstream/main"
      ISSUES=$((ISSUES + 1))
    fi
  else
    echo "skipped (no branch)"
  fi

  # ─── Check open PR branches for conflicts (read-only, no modification) ───
  echo "  Checking open PR branches for conflicts..."

  OPEN_PRS=$(timeout 60 gh pr list --repo Red-Blink/dune-awakening-selfhost-docker --author yacketrj --state open --json headRefName,number,title,mergeable --jq '.[] | "\(.headRefName)\t\(.number)\t\(.title)\t\(.mergeable)"' 2>/dev/null || echo "")

  while IFS=$'\t' read -r branch pr title mergeable; do
    [ -n "$branch" ] || continue
    echo -n "    $branch (#$pr): "
    if [ "$mergeable" = "MERGEABLE" ]; then
      echo -e "${GREEN}MERGEABLE${NC}"
    elif [ "$mergeable" = "CONFLICTING" ]; then
      echo -e "${RED}CONFLICT${NC}"
      REPORT="${REPORT}\n❌ PR #$pr ($branch) conflicts with upstream/main — \"$title\""
      ISSUES=$((ISSUES + 1))
      # File GitHub issue for conflict
      FINGERPRINT="conflict-${pr}-$(date +%Y%m%d)"
      if ! grep -q "$FINGERPRINT" "$STATE_FILE" 2>/dev/null; then
        timeout 30 gh issue create --title "fix: PR #$pr ($branch) conflicts with upstream/main — needs rebase" \
          --label "bug,severity:high" \
          --body "PR https://github.com/Red-Blink/dune-awakening-selfhost-docker/pull/$pr has merge conflicts with the latest upstream release. The branch \`$branch\` needs to be rebased onto \`upstream/main\` and force-pushed." \
          --repo Project-Arrakis/dune-awakening-selfhost-docker 2>/dev/null && echo "$FINGERPRINT" >> "$STATE_FILE" || true
      fi
    else
      echo -e "${YELLOW}$mergeable${NC}"
    fi
  done <<< "$OPEN_PRS"

  # ─── Clean up stale merged PR branches ───
  echo -n "  Cleaning merged branches: "
  MERGED_BRANCHES=$(timeout 60 gh pr list --repo Red-Blink/dune-awakening-selfhost-docker --author yacketrj --state merged --limit 20 --json headRefName --jq '.[].headRefName' 2>/dev/null || echo "")
  CLEANED=0
  for branch in $MERGED_BRANCHES; do
    if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      git push origin --delete "$branch" 2>/dev/null && CLEANED=$((CLEANED + 1)) || true
    fi
    git branch -D "$branch" 2>/dev/null || true
  done
  echo "$CLEANED removed"

  # Restore previous state
  if [ "$STASHED" = true ]; then
    git checkout "$CURRENT_BRANCH" 2>/dev/null || true
    git stash pop 2>/dev/null || true
  elif [ "$CURRENT_BRANCH" != "main" ]; then
    git checkout "$CURRENT_BRANCH" 2>/dev/null || git checkout integration/discord 2>/dev/null || true
  fi
elif [ "$SYNC_STATUS" = "diverged" ]; then
  # origin/main is AHEAD of or has DIVERGED from upstream/main (has
  # fork-local merged work upstream doesn't have) — this is expected and
  # healthy, NOT an error condition, and must never trigger a reset. This
  # is the exact case that caused the 2026-07-22 incidents when the old
  # logic didn't distinguish it from "genuinely behind" — see
  # lib/sync-direction.sh and tests/sync-direction.bats.
  #
  # BUG FIX (2026-08-15): "must never auto-sync" (correct, unchanged
  # above) had silently become "must never even mention it again" --
  # this branch logged one green line, forever, no matter how large
  # $BEHIND grew or how long it had been growing, with zero threshold
  # and zero use of $BEHIND (which was already computed above, just
  # never read here). Confirmed via a real, concrete case this let
  # through undetected: our own upstream PR #134 (RBAC/IAM policy
  # engine) merged into Red-Blink/dune-awakening-selfhost-docker on
  # 2026-08-11; the maintainer made a real follow-up fix on top of it
  # shortly after that this fork's main never pulled back down. By the
  # time this was found independently (dune-awakening-selfhost-docker
  # #279), the fork was 162 commits ahead / 150 behind, with real,
  # security-relevant divergence across ~13 files -- and this monitor
  # had reported "OK... by design" on every single one of those hourly
  # runs, despite already knowing the exact behind-count each time.
  # "Ahead-only, never behind" genuinely doesn't need a human -- that
  # really is the healthy, by-design case the comment above describes.
  # "Ahead AND behind" means real upstream commits exist that this
  # fork's main hasn't reconciled, which needs a human to actually look
  # at, not a green log line. Mirrors the exact state-file-dedup +
  # gh issue create pattern already used by the release-detection block
  # above (section 0), so a fresh divergence is reported once, not every
  # hour forever, and a GROWING divergence (BEHIND increasing since last
  # report) re-notifies rather than staying silent just because an issue
  # was already filed once for a smaller gap.
  #
  # BUG FIX (2026-08-17, acp-ops-monitor#33): the state file above only
  # ever recorded the last-reported BEHIND count, never the GitHub issue
  # number it was reported on. That meant every time BEHIND grew, this
  # branch called `gh issue create` again -- filing a brand new issue
  # instead of updating the one already open for the same underlying,
  # still-unreconciled divergence. Confirmed in the wild: #289, #297,
  # #298, #300 (and later #310, #312, #314) were four/seven separate
  # open issues describing the exact same problem at different
  # snapshots, none of which this script ever closed even after #279/#316
  # actually reconciled the fork. Fixed by storing "BEHIND ISSUE_NUMBER"
  # in the state file: a growing count now COMMENTS on the existing open
  # issue (falling back to creating one only if none is tracked, or the
  # tracked one is no longer open) instead of creating a new one, and the
  # BEHIND==0 (resolved) path now closes the tracked issue with a
  # resolution comment instead of just silently going green.
  DIVERGENCE_STATE_FILE="${HOME}/.cache/acp-ops-monitor/known-divergence-behind-count.txt"
  mkdir -p "$(dirname "$DIVERGENCE_STATE_FILE")"
  touch "$DIVERGENCE_STATE_FILE"
  read -r LAST_REPORTED_BEHIND LAST_ISSUE_NUMBER < "$DIVERGENCE_STATE_FILE" 2>/dev/null || true
  [[ "${LAST_REPORTED_BEHIND:-}" =~ ^[0-9]+$ ]] || LAST_REPORTED_BEHIND=0
  [[ "${LAST_ISSUE_NUMBER:-}" =~ ^[0-9]+$ ]] || LAST_ISSUE_NUMBER=""

  if [ "$BEHIND" -gt 0 ]; then
    if [ "$BEHIND" -gt "$LAST_REPORTED_BEHIND" ]; then
      echo -e "  ${YELLOW}DIVERGED:${NC} core fork main is $AHEAD_OF_UPSTREAM commits ahead AND $BEHIND commits behind upstream/main — real upstream work is not yet reconciled (was $LAST_REPORTED_BEHIND commits behind at last report)"
      DIVERGENCE_COMMIT_LIST=$(git log --oneline origin/main..upstream/main 2>/dev/null | head -10 || echo "unknown")

      # Only reuse the tracked issue number if it's still actually open --
      # an operator may have manually closed/superseded it without this
      # script's knowledge, in which case falling through to create a new
      # one is correct, not a regression back to the old duplicate-filing bug.
      TRACKED_ISSUE_STATE=""
      if [ -n "$LAST_ISSUE_NUMBER" ]; then
        TRACKED_ISSUE_STATE=$(timeout 30 gh issue view "$LAST_ISSUE_NUMBER" \
          --repo Project-Arrakis/dune-awakening-selfhost-docker \
          --json state -q .state 2>/dev/null || echo "")
      fi

      if [ "$TRACKED_ISSUE_STATE" = "OPEN" ]; then
        echo "  Updating existing open divergence issue #$LAST_ISSUE_NUMBER instead of filing a duplicate."
        timeout 30 gh issue comment "$LAST_ISSUE_NUMBER" \
          --repo Project-Arrakis/dune-awakening-selfhost-docker \
          --body "Divergence has grown: now **$AHEAD_OF_UPSTREAM commits ahead**, **$BEHIND commits behind** (was $LAST_REPORTED_BEHIND behind at last report).

Most recent commits this fork is missing:
\`\`\`
$DIVERGENCE_COMMIT_LIST
\`\`\`

Still needs a human (or agent) to review and merge \`upstream/main\` in deliberately (never reset/force-push)." 2>/dev/null
        NEW_ISSUE_NUMBER="$LAST_ISSUE_NUMBER"
      else
        NEW_ISSUE_URL=$(timeout 30 gh issue create \
          --title "fork/upstream divergence: main is $AHEAD_OF_UPSTREAM ahead / $BEHIND behind upstream/main — needs reconciliation" \
          --label "bug,severity:high" \
          --body "This fork's \`main\` has diverged from \`Red-Blink/dune-awakening-selfhost-docker\`'s \`main\`: **$AHEAD_OF_UPSTREAM commits ahead**, **$BEHIND commits behind**.

Being ahead alone is expected (local work not yet upstreamed) — this issue exists specifically because \`main\` is ALSO behind, meaning real upstream commits exist that this fork has not reconciled. This is never auto-synced (a genuinely diverged fork must not be fast-forwarded or reset — see this repo's own incident history), so it needs a human (or agent) to review and merge \`upstream/main\` in deliberately.

Most recent commits this fork is missing:
\`\`\`
$DIVERGENCE_COMMIT_LIST
\`\`\`

Action needed: review what upstream changed, merge \`upstream/main\` into this fork's \`main\` (never reset/force-push), resolve any real conflicts, verify CI." \
          --repo Project-Arrakis/dune-awakening-selfhost-docker 2>/dev/null || echo "")
        NEW_ISSUE_NUMBER="${NEW_ISSUE_URL##*/}"
      fi

      printf '%s %s\n' "$BEHIND" "$NEW_ISSUE_NUMBER" > "$DIVERGENCE_STATE_FILE"
      REPORT="${REPORT}\n⚠️ Core fork main diverged: $AHEAD_OF_UPSTREAM ahead / $BEHIND behind upstream — needs reconciliation (#${NEW_ISSUE_NUMBER:-unknown})"
      ISSUES=$((ISSUES + 1))
    else
      echo -e "  ${GREEN}OK:${NC} core fork main is $AHEAD_OF_UPSTREAM ahead / $BEHIND behind upstream — already reported on #${LAST_ISSUE_NUMBER:-unknown}, no growth since last check"
    fi
  else
    echo -e "  ${GREEN}OK:${NC} core fork main is ahead of upstream by design (local merges not yet upstreamed), not behind — not syncing"
    # Divergence resolved (BEHIND returned to 0) -- auto-close the
    # tracked issue instead of leaving it open forever with no signal
    # that the underlying problem is gone.
    if [ -n "$LAST_ISSUE_NUMBER" ]; then
      TRACKED_ISSUE_STATE=$(timeout 30 gh issue view "$LAST_ISSUE_NUMBER" \
        --repo Project-Arrakis/dune-awakening-selfhost-docker \
        --json state -q .state 2>/dev/null || echo "")
      if [ "$TRACKED_ISSUE_STATE" = "OPEN" ]; then
        echo "  RESOLVED: closing divergence issue #$LAST_ISSUE_NUMBER (behind count returned to 0)"
        timeout 30 gh issue close "$LAST_ISSUE_NUMBER" \
          --repo Project-Arrakis/dune-awakening-selfhost-docker \
          --comment "Auto-closed: fork main is no longer behind upstream/main (\`BEHIND\` returned to 0 as of this check). Reconciliation is complete." 2>/dev/null || true
        REPORT="${REPORT}\n✅ Core fork divergence resolved — closed #$LAST_ISSUE_NUMBER"
      fi
      rm -f "$DIVERGENCE_STATE_FILE"
    fi
  fi
else
  echo -e "  ${GREEN}OK:${NC} core fork synced ($(echo "$UPSTREAM" | cut -c1-7))"
fi

# ─── 2. Catalog fork sync ───
echo "--- 2. Catalog fork sync ---"
if [ -d "$CATALOG_DIR" ]; then
  cd "$CATALOG_DIR"
  git fetch upstream main --quiet 2>/dev/null || true
  git fetch origin main --quiet 2>/dev/null || true
  CAT_UP=$(git rev-parse upstream/main 2>/dev/null || echo "")
  CAT_OR=$(git rev-parse origin/main 2>/dev/null || echo "")
  # Same direction-blind bug as the core fork sync above — fixed the same
  # way: only sync when origin/main is a strict, pure ancestor of
  # upstream/main (genuinely behind, nothing of its own to lose). ALSO
  # fixed the same second bug (2026-07-25): reset --hard was replaced
  # with merge --ff-only so a timing-window false-positive on the AHEAD
  # check above fails safely instead of destructively — see the detailed
  # fix note on the core-fork-sync block above for the real incident this
  # was found from.
  CAT_AHEAD=$(git rev-list upstream/main..origin/main --count 2>/dev/null || echo "0")
  if [ -n "$CAT_UP" ] && [ -n "$CAT_OR" ] && [ "$CAT_UP" != "$CAT_OR" ] && [ "$CAT_AHEAD" = "0" ]; then
    BEHIND=$(git rev-list origin/main..upstream/main --count 2>/dev/null || echo "?")
    echo "  SYNC: catalog fork $BEHIND commits behind — syncing..."
    git checkout main 2>/dev/null || true
    if git merge --ff-only upstream/main 2>/dev/null; then
      # BUG FIX (2026-07-25): --no-verify removed, same reasoning as the
      # core-fork main sync above -- this is a real, consequential push
      # to this fork's real main, not disposable WIP.
      PUSH_OUT="$(git push origin main 2>&1)"
      PUSH_RC="${PIPESTATUS[0]:-$?}"
      echo "$PUSH_OUT" | tail -3
      if [ "$PUSH_RC" -eq 0 ]; then
        echo -e "  ${GREEN}OK:${NC} catalog synced"
      else
        echo -e "  ${RED}PUSH BLOCKED (gate failure):${NC} catalog main was fast-forwarded locally but the push was blocked — investigate manually"
        REPORT="${REPORT}\n❌ Catalog fork main push blocked by pre-push gate after fast-forwarding to upstream — local/origin now diverge, needs manual attention"
        ISSUES=$((ISSUES + 1))
      fi
    else
      # BUG FIX (2026-07-25): this branch previously fell through to an
      # unconditional "OK: catalog synced" message right after reporting
      # ABORTED above it -- a real, separate bug that misreported failure
      # as success. Now correctly does NOT print the success message.
      echo -e "  ${RED}ABORTED:${NC} catalog main has local history that would be lost by a fast-forward — not syncing."
      REPORT="${REPORT}\n❌ Catalog fork main could not be fast-forwarded to upstream (local-only history present) — manual sync needed"
      ISSUES=$((ISSUES + 1))
    fi
  elif [ -n "$CAT_UP" ] && [ -n "$CAT_OR" ] && [ "$CAT_UP" != "$CAT_OR" ]; then
    echo -e "  ${GREEN}OK:${NC} catalog fork main is ahead of/diverged from upstream by design — not syncing"
  elif [ -n "$CAT_UP" ] && [ -n "$CAT_OR" ] && [ "$CAT_UP" = "$CAT_OR" ]; then
    # BUG FIX (2026-07-25): this case (both refs resolved and already
    # equal, i.e. genuinely fully synced) previously fell through to the
    # generic "remotes not configured" message below, which is
    # misleading -- upstream and origin were both reachable and
    # identical, not unconfigured.
    echo -e "  ${GREEN}OK:${NC} catalog fork already synced ($(echo "$CAT_UP" | cut -c1-7))"
  else
    echo -e "  ${YELLOW}SKIP:${NC} catalog fork remotes not configured"
  fi
else
  echo "  SKIP: catalog dir not found"
fi

# ─── 3. PR mergeability check ───
echo "--- 3. PR mergeability ---"

# BUG FIX (issue #38): GitHub computes a PR's `mergeable` field
# asynchronously -- a query can legitimately return "UNKNOWN" for a few
# seconds after a push/query while the backend is still computing merge
# conflicts, before settling to MERGEABLE or CONFLICTING. The
# `gh pr list` call below is a single point-in-time snapshot with no way
# to tell "still computing" apart from a real finding, so an hourly run
# that happens to land during that window previously reported a
# perfectly healthy, mergeable PR as a hard failure (confirmed live:
# PRs #189/#201/#202 alerted as UNKNOWN, then read back as stably
# MERGEABLE seconds later). Re-poll that one PR directly a few times
# before trusting UNKNOWN as a real result.
resolve_mergeable() {
  local repo="$1" pr="$2" val="$3" _attempt
  for _attempt in 1 2 3; do
    [ "$val" != "UNKNOWN" ] && break
    sleep 2
    val="$(timeout 30 gh pr view "$pr" --repo "$repo" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")"
  done
  echo "$val"
}

check_prs() {
  local repo="$1" label="$2"
  while IFS=$'\t' read -r pr title mergeable; do
    if [ "$mergeable" = "UNKNOWN" ]; then
      mergeable="$(resolve_mergeable "$repo" "$pr" "$mergeable")"
    fi
    if [ "$mergeable" = "MERGEABLE" ]; then
      echo -e "  ${GREEN}OK:${NC} PR #$pr ($label) — MERGEABLE"
    else
      echo -e "  ${RED}FAIL:${NC} PR #$pr ($label) — $mergeable"
      REPORT="${REPORT}\n❌ PR #$pr ($label) — **$mergeable** — $title"
      ISSUES=$((ISSUES + 1))
    fi
  done < <(timeout 60 gh pr list --repo "$repo" --author yacketrj --state open --json number,title,mergeable --jq '.[] | "\(.number)\t\(.title)\t\(.mergeable)"' 2>/dev/null)
}
check_prs "Red-Blink/dune-awakening-selfhost-docker" "Core"
check_prs "Red-Blink/dune-docker-addons" "Catalog"

# ─── 3b. Recently merged/closed PRs ───
echo "--- 3b. Recent PR activity ---"
PR_STATE_FILE="${HOME}/.cache/acp-ops-monitor/known-prs.txt"
mkdir -p "$(dirname "$PR_STATE_FILE")"
touch "$PR_STATE_FILE"

CORE_DIR_PR="${CORE_DIR}"
cd "$CORE_DIR_PR" 2>/dev/null || true

while IFS=$'\t' read -r pr title mergedAt; do
  if ! grep -q "^merged:$pr$" "$PR_STATE_FILE" 2>/dev/null; then
    echo -e "  ${GREEN}NEW MERGED:${NC} PR #$pr (Core) — $title"
    REPORT="${REPORT}\n✅ PR #$pr (Core) merged — $title"
    ACTIVITY=$((ACTIVITY + 1))
    echo "merged:$pr" >> "$PR_STATE_FILE"
  else
    echo -e "  ${GREEN}OK:${NC} PR #$pr (Core) — merged $mergedAt"
  fi
done < <(timeout 60 gh pr list --repo Red-Blink/dune-awakening-selfhost-docker --author yacketrj --state merged --limit 10 --json number,title,mergedAt --jq '.[] | "\(.number)\t\(.title)\t\(.mergedAt)"' 2>/dev/null)

while IFS=$'\t' read -r pr title; do
  if ! grep -q "^merged:$pr$" "$PR_STATE_FILE" 2>/dev/null && ! grep -q "^closed:$pr$" "$PR_STATE_FILE" 2>/dev/null; then
    echo -e "  ${YELLOW}NEW CLOSED:${NC} PR #$pr (Core) — $title"
    REPORT="${REPORT}\n🔒 PR #$pr (Core) closed — $title"
    ACTIVITY=$((ACTIVITY + 1))
    echo "closed:$pr" >> "$PR_STATE_FILE"
  fi
done < <(timeout 60 gh pr list --repo Red-Blink/dune-awakening-selfhost-docker --author yacketrj --state closed --limit 10 --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null)

# ─── 4. CI failure check ───
# Updated 2026-07-25: added acp-ops-monitor (this repo) and tools to the
# checked list -- per ~/README.md's Strict Requirement #1 ("no repo's
# GitHub Actions may be left in a failing state on its default branch"),
# every repo this workstream maintains should be covered here, not just
# the Dune/ACP application repos. Found via this exact gap: this repo's
# own CI had been failing on main for several hours before being noticed
# manually, specifically because this check didn't include itself.
# Delegates to lib/ci-health.sh (shared with check-upstream-prs.sh) --
# see that file's header for the two real bugs this replaced: `gh run
# list --limit 1` picking an unrelated workflow's run instead of the one
# with the real security jobs, and being blind to a job reporting
# "success" while its scanner silently never ran.
echo "--- 4. CI failures ---"
for r in Project-Arrakis/dune-awakening-selfhost-docker Project-Arrakis/dune-ops-observability-addon Project-Arrakis/dune-docker-addons Project-Arrakis/sentinel Project-Arrakis/sentinel-web Project-Arrakis/sentinel-ops-monitor yacketrj/tools; do
  REPO_NAME=$(echo "$r" | cut -d'/' -f2)
  ISSUES_BEFORE=$ISSUES
  check_ci_health "$r" "$REPO_NAME" || true
  if [ "$ISSUES" -gt "$ISSUES_BEFORE" ]; then
    REPORT="${REPORT}\n⚠️ **$REPO_NAME** — latest CI needs resolution (see monitor log for detail: failure, or a scanner may have silently skipped)"
  fi
done

# ─── 5. Failed systemd units ───
# Added 2026-07-25: this host runs real, unattended systemd services/timers
# for this project (the live Discord bot, the game-server DB backup timer)
# with no prior monitoring for silent failures. Found and fixed a real
# case of this exact gap during the same cleanup work that added this
# check: dune-awakening-db-backup.service had been failing daily since at
# least 2026-07-23 (WorkingDirectory pointed at a stale, already-deleted
# repo path -- the same class of bug as the auto-update timer fixed
# earlier this session), undetected until a manual `systemctl --failed`
# audit. This section closes that detection gap going forward using the
# same report/issue pattern as the rest of this script, rather than
# relying on a human to remember to check.
echo "--- 5. Failed systemd units ---"
FAILED_UNITS="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
if [ -n "$FAILED_UNITS" ]; then
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    echo -e "  ${RED}FAIL:${NC} $unit is in a failed state"
    REPORT="${REPORT}\n⚠️ systemd unit **$unit** is in a failed state — run \`systemctl status $unit\` to investigate"
    ISSUES=$((ISSUES + 1))
  done <<< "$FAILED_UNITS"
else
  echo -e "  ${GREEN}OK:${NC} no failed systemd units"
fi

# ─── 6. Home directory structure ───
# Added 2026-07-25: after a full home-directory reorganization (see
# ~/archive/2026-07-25-reorg-notes.md), wired structure-lint into this
# hourly run so structure drift (a repo moved/duplicated outside
# ~/projects, a basename/slug mismatch, ~/tools falling off $PATH) is
# caught automatically going forward instead of only being noticed
# the next time someone happens to look.
echo "--- 6. Home directory structure ---"
STRUCTURE_LINT="${HOME}/tools/structure-lint"
if [ -x "$STRUCTURE_LINT" ]; then
  STRUCTURE_OUT="$("$STRUCTURE_LINT" 2>&1)"
  STRUCTURE_RC=$?
  if [ "$STRUCTURE_RC" -eq 0 ]; then
    echo -e "  ${GREEN}OK:${NC} structure-lint passed"
  else
    echo -e "  ${RED}FAIL:${NC} structure-lint found $STRUCTURE_RC issue(s)"
    echo "$STRUCTURE_OUT" | grep "FAIL:" | while IFS= read -r line; do
      echo "  $line"
    done
    REPORT="${REPORT}\n⚠️ Home directory structure-lint found $STRUCTURE_RC issue(s) — run \`~/tools/structure-lint\` to investigate"
    ISSUES=$((ISSUES + 1))
  fi
else
  echo -e "  ${YELLOW}SKIP:${NC} ~/tools/structure-lint not found or not executable"
fi


# ─── 6b. Upstream test drift ───
echo "--- 6b. Upstream test drift ---"
# BUG FIX (2026-08-15): was a second, independently hardcoded stale path
# to the same repo $CORE_DIR already points at -- reuse $CORE_DIR so
# there is exactly one place this account's real Core clone path is
# defined, not two that can silently drift apart again. See Arrakis-Project#24.
DRIFT_SCRIPT="${CORE_DIR}/scripts/check-upstream-test-drift.sh"
if [ -x "$DRIFT_SCRIPT" ]; then
  DRIFT_OUT="$("$DRIFT_SCRIPT" 2>&1)"
  DRIFT_RC=$?
  if [ "$DRIFT_RC" -eq 0 ]; then
    echo -e "  ${GREEN}OK:${NC} no upstream test drift"
  else
    echo -e "  ${YELLOW}DRIFT:${NC} upstream tests have diverged or new tests detected"
    echo "$DRIFT_OUT" | while IFS= read -r line; do
      echo "  $line"
    done
  fi
else
  echo -e "  ${YELLOW}SKIP:${NC} drift checker not found — lives on Core PR branch"
fi

# ─── 7. Summary + Issue Tracking ───
STATE_FILE="${HOME}/.cache/acp-ops-monitor/issue-state.txt"
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

# Prune state files older than 30 days (prevents unbounded growth)
for f in "$STATE_FILE" "${HOME}/.cache/acp-ops-monitor/pr-states.json"; do
  if [ -f "$f" ]; then
    find "$(dirname "$f")" -name "$(basename "$f")" -mtime +30 -delete 2>/dev/null || true
  fi
done

echo
# Build issue fingerprint from REPORT
if [ "$ISSUES" -gt 0 ]; then
  FINGERPRINT=$(echo "$REPORT" | md5sum | cut -c1-8)
else
  FINGERPRINT="clean"
fi

# Check for resolved issues (were OPEN, now clean or different fingerprint)
RESOLVED=""
while IFS=" " read -r old_fingerprint _old_report_short; do
  if [ "$old_fingerprint" != "$FINGERPRINT" ] && [ -n "$old_fingerprint" ]; then
    RESOLVED="${RESOLVED}✅ Issue \`${old_fingerprint}\` resolved\n"
  fi
done < "$STATE_FILE"

# Update state file
if [ "$ISSUES" -gt 0 ]; then
  echo "$FINGERPRINT ${REPORT:0:80}" > "$STATE_FILE"
else
  : > "$STATE_FILE"
fi

# Send notifications
if [ "$ISSUES" -eq 0 ] && [ -n "$RESOLVED" ]; then
  echo -e "${GREEN}Issues resolved.${NC} $ACTIVITY new PR events. Sending resolution notification."
  if [ -x "$NOTIFY" ]; then
    bash "$NOTIFY" deploy \
      "✅ ACP Validation — Issues Resolved" \
      "All previously detected issues are now resolved. CI clean across all repos. $ACTIVITY PR events detected." \
      "" 5763719 >/dev/null 2>&1 || true
  fi
elif [ "$ISSUES" -eq 0 ]; then
  # Only send "All Clear" when transitioning from issues→clean, NOT when
  # staying clean (suppresses 24 noisy notifications/day). If the previous
  # fingerprint was already "clean", skip — nothing changed.
  #
  # BUG FIX (2026-08-15): `local` is only valid inside a function --
  # this entire script is flat (no function wraps this section), so
  # this was a real shellcheck ERROR (SC2168), not just a warning, and
  # had been failing this repo's own CI on main since at least
  # 2026-08-10 (confirmed via `gh run list --workflow=ci.yml`). Plain
  # variable assignment is correct here; there is no enclosing function
  # for `local` to scope this to.
  OLD_FINGERPRINT=""
  if [ -f "$STATE_FILE" ]; then
    read -r OLD_FINGERPRINT _ < "$STATE_FILE" 2>/dev/null || true
  fi
  if [ "$OLD_FINGERPRINT" = "clean" ]; then
    echo -e "${GREEN}All checks passed.${NC} $ACTIVITY new PR events. Skipping notification (state unchanged)."
  else
    echo -e "${GREEN}All checks passed.${NC} $ACTIVITY new PR events. Sending status update."
    if [ -x "$NOTIFY" ]; then
      bash "$NOTIFY" deploy \
        "✅ ACP Validation — All Clear" \
        "Core fork synced. All PRs MERGEABLE. CI clean. $ACTIVITY PR events detected." \
        "" 5763719 >/dev/null 2>&1 || true
    fi
  fi
else
  echo -e "${RED}$ISSUES issue(s) found.${NC} $ACTIVITY PR events. Sending Discord notification."
  if [ -x "$NOTIFY" ]; then
    bash "$NOTIFY" deploy \
      "⚠️ ACP Validation — $ISSUES issue(s)" \
      "$REPORT" \
      "" 16744192 >/dev/null 2>&1 || true
  fi
fi
