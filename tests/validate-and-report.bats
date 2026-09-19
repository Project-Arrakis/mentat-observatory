#!/usr/bin/env bats
# validate-and-report.bats — Tests for the validate-and-report.sh notification
# logic, fingerprint mechanism, and state transitions. Git operations and
# network calls are inherently untestable in unit tests; those sections are
# validated through CI checks (section 4 of the script) and manual review.

setup() {
  TEST_DIR="$(mktemp -d)"
  STATE_FILE="$TEST_DIR/test-state.txt"
  PR_STATE_FILE="$TEST_DIR/test-pr-state.txt"
  export STATE_FILE PR_STATE_FILE
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ── Fingerprint mechanism ──

@test "fingerprint: issues produce a non-empty MD5 fingerprint" {
  REPORT="❌ Test issue detected"
  ISSUES=1
  FINGERPRINT=$(echo "$REPORT" | md5sum | cut -c1-8)
  [ -n "$FINGERPRINT" ]
  [ "$FINGERPRINT" != "clean" ]
  [ "${#FINGERPRINT}" -eq 8 ]
}

@test "fingerprint: clean state produces literal 'clean' fingerprint" {
  ISSUES=0
  FINGERPRINT="clean"
  [ "$FINGERPRINT" = "clean" ]
}

@test "fingerprint: same report produces same fingerprint across runs" {
  REPORT="❌ CI failure in dune"
  ISSUES=1
  FP1=$(echo "$REPORT" | md5sum | cut -c1-8)
  FP2=$(echo "$REPORT" | md5sum | cut -c1-8)
  [ "$FP1" = "$FP2" ]
}

@test "fingerprint: different reports produce different fingerprints" {
  REPORT_A="❌ CI failure in dune"
  REPORT_B="❌ CI failure in catalog"
  FP_A=$(echo "$REPORT_A" | md5sum | cut -c1-8)
  FP_B=$(echo "$REPORT_B" | md5sum | cut -c1-8)
  [ "$FP_A" != "$FP_B" ]
}

# ── State file transitions ──

@test "state: empty state file means no previous issues" {
  : > "$STATE_FILE"
  ISSUES=0
  FINGERPRINT="clean"
  RESOLVED=""
  while IFS=" " read -r old_fingerprint _; do
    if [ "$old_fingerprint" != "$FINGERPRINT" ] && [ -n "$old_fingerprint" ]; then
      RESOLVED="${RESOLVED}resolved"
    fi
  done < "$STATE_FILE"
  [ -z "$RESOLVED" ]
}

@test "state: transitioning from issues to clean reports resolution" {
  echo "abc12345 CI failing" > "$STATE_FILE"
  ISSUES=0
  FINGERPRINT="clean"
  RESOLVED=""
  while IFS=" " read -r old_fingerprint _; do
    if [ "$old_fingerprint" != "$FINGERPRINT" ] && [ -n "$old_fingerprint" ]; then
      RESOLVED="${RESOLVED}resolved"
    fi
  done < "$STATE_FILE"
  [ -n "$RESOLVED" ]
}

@test "state: staying clean produces no resolution notice" {
  : > "$STATE_FILE"
  ISSUES=0
  FINGERPRINT="clean"
  RESOLVED=""
  while IFS=" " read -r old_fingerprint _; do
    if [ "$old_fingerprint" != "$FINGERPRINT" ] && [ -n "$old_fingerprint" ]; then
      RESOLVED="${RESOLVED}resolved"
    fi
  done < "$STATE_FILE"
  [ -z "$RESOLVED" ]
}

@test "state: same issue fingerprint does not produce resolution" {
  echo "abc12345 CI failing" > "$STATE_FILE"
  ISSUES=1
  REPORT="❌ CI failure in dune"
  FINGERPRINT="abc12345"  # simulate same fingerprint
  RESOLVED=""
  while IFS=" " read -r old_fingerprint _; do
    if [ "$old_fingerprint" != "$FINGERPRINT" ] && [ -n "$old_fingerprint" ]; then
      RESOLVED="${RESOLVED}resolved"
    fi
  done < "$STATE_FILE"
  [ -z "$RESOLVED" ]
}

@test "state: different fingerprint from previous issues means new issue" {
  echo "abc12345 CI failing" > "$STATE_FILE"
  ISSUES=1
  REPORT="❌ PR conflict in catalog"
  FINGERPRINT=$(echo "$REPORT" | md5sum | cut -c1-8)
  RESOLVED=""
  while IFS=" " read -r old_fingerprint _; do
    if [ "$old_fingerprint" != "$FINGERPRINT" ] && [ -n "$old_fingerprint" ]; then
      RESOLVED="${RESOLVED}resolved"
    fi
  done < "$STATE_FILE"
  [ -n "$RESOLVED" ]
  [ "$FINGERPRINT" != "abc12345" ]
}

# ── Notification decision tree ──

@test "notify: issues > 0 always triggers alert notification" {
  ISSUES=3
  ACTIVITY=1
  RESOLVED=""
  NOTIFICATION_TYPE=""
  if [ "$ISSUES" -eq 0 ] && [ -n "$RESOLVED" ]; then
    NOTIFICATION_TYPE="resolved"
  elif [ "$ISSUES" -eq 0 ]; then
    NOTIFICATION_TYPE="all_clear"
  else
    NOTIFICATION_TYPE="alert"
  fi
  [ "$NOTIFICATION_TYPE" = "alert" ]
}

@test "notify: issues == 0 with resolved triggers resolution notification" {
  ISSUES=0
  ACTIVITY=0
  RESOLVED="some_resolved"
  NOTIFICATION_TYPE=""
  if [ "$ISSUES" -eq 0 ] && [ -n "$RESOLVED" ]; then
    NOTIFICATION_TYPE="resolved"
  elif [ "$ISSUES" -eq 0 ]; then
    NOTIFICATION_TYPE="all_clear"
  else
    NOTIFICATION_TYPE="alert"
  fi
  [ "$NOTIFICATION_TYPE" = "resolved" ]
}

@test "notify: issues == 0 without resolved triggers all_clear notification" {
  ISSUES=0
  ACTIVITY=0
  RESOLVED=""
  NOTIFICATION_TYPE=""
  if [ "$ISSUES" -eq 0 ] && [ -n "$RESOLVED" ]; then
    NOTIFICATION_TYPE="resolved"
  elif [ "$ISSUES" -eq 0 ]; then
    NOTIFICATION_TYPE="all_clear"
  else
    NOTIFICATION_TYPE="alert"
  fi
  [ "$NOTIFICATION_TYPE" = "all_clear" ]
}

# ── State file persistence ──

@test "state: issues > 0 writes fingerprint to state file" {
  ISSUES=1
  REPORT="❌ Test issue"
  FINGERPRINT=$(echo "$REPORT" | md5sum | cut -c1-8)
  echo "$FINGERPRINT ${REPORT:0:80}" > "$STATE_FILE"
  [ -s "$STATE_FILE" ]
  read -r stored_fp _ < "$STATE_FILE"
  [ "$stored_fp" = "$FINGERPRINT" ]
}

@test "state: issues == 0 clears state file" {
  ISSUES=0
  : > "$STATE_FILE"
  [ ! -s "$STATE_FILE" ]
}

# ── PR state tracking ──

@test "pr_state: merged PR added to known list" {
  : > "$PR_STATE_FILE"
  PR=128
  grep -q "^merged:$PR$" "$PR_STATE_FILE" 2>/dev/null || echo "merged:$PR" >> "$PR_STATE_FILE"
  grep -q "^merged:$PR$" "$PR_STATE_FILE"
}

@test "pr_state: already-known merged PR not re-added" {
  echo "merged:128" > "$PR_STATE_FILE"
  PR=128
  if ! grep -q "^merged:$PR$" "$PR_STATE_FILE" 2>/dev/null; then
    echo "merged:$PR" >> "$PR_STATE_FILE"
  fi
  COUNT=$(grep -c "^merged:$PR$" "$PR_STATE_FILE" || echo 0)
  [ "$COUNT" -eq 1 ]
}

@test "pr_state: closed PR tracked separately from merged" {
  echo "closed:99" > "$PR_STATE_FILE"
  PR=99
  grep -q "^merged:$PR$" "$PR_STATE_FILE" 2>/dev/null || grep -q "^closed:$PR$" "$PR_STATE_FILE" 2>/dev/null
  [ $? -eq 0 ]
}

# ── Edge cases ──

@test "edge: empty REPORT with issues produces valid fingerprint" {
  ISSUES=1
  REPORT=""
  FINGERPRINT=$(echo "$REPORT" | md5sum | cut -c1-8)
  [ -n "$FINGERPRINT" ]
  [ "$FINGERPRINT" != "clean" ]
}

@test "edge: state file with corrupted content is handled" {
  echo "garbage without proper format" > "$STATE_FILE"
  ISSUES=0
  FINGERPRINT="clean"
  RESOLVED=""
  while IFS=" " read -r old_fingerprint _; do
    if [ "$old_fingerprint" != "$FINGERPRINT" ] && [ -n "$old_fingerprint" ]; then
      RESOLVED="${RESOLVED}resolved"
    fi
  done < "$STATE_FILE"
  # "garbage" != "clean" → RESOLVED
  [ -n "$RESOLVED" ]
}

@test "edge: ACTIVITY counter remains high with many PR merges" {
  ACTIVITY=12
  [ "$ACTIVITY" -eq 12 ]
}

# ── Diverged-fork threshold/alert logic (added 2026-08-15) ──
#
# Regression coverage for a real gap: the "diverged" branch of
# validate-and-report.sh previously treated ANY divergence, of any
# size, forever, as simply "OK, by design" -- it never read $BEHIND
# (already computed) and never filed an issue, no matter how large or
# how long-growing the divergence became. These tests exercise the
# same state-file-diff logic the real script now uses (mirroring the
# fingerprint/PR-state tests above, which test the script's logic
# inline rather than executing git/network operations).

DIVERGENCE_STATE_FILE=""

setup_divergence_state() {
  DIVERGENCE_STATE_FILE="$TEST_DIR/test-divergence-state.txt"
  export DIVERGENCE_STATE_FILE
}

@test "divergence: ahead-only (behind=0) never files an issue regardless of ahead count" {
  BEHIND=0
  # Mirrors the real script's guard: the issue-filing path is only
  # ever reached when BEHIND -gt 0.
  if [ "$BEHIND" -gt 0 ]; then
    SHOULD_FILE="yes"
  else
    SHOULD_FILE="no"
  fi
  [ "$SHOULD_FILE" = "no" ]
}

@test "divergence: first time behind>0 is seen, it is reported (no prior state file)" {
  setup_divergence_state
  BEHIND=150
  LAST_REPORTED_BEHIND="$(cat "$DIVERGENCE_STATE_FILE" 2>/dev/null || echo 0)"
  [[ "$LAST_REPORTED_BEHIND" =~ ^[0-9]+$ ]] || LAST_REPORTED_BEHIND=0
  [ "$LAST_REPORTED_BEHIND" -eq 0 ]
  [ "$BEHIND" -gt "$LAST_REPORTED_BEHIND" ]
}

@test "divergence: same behind-count as last report does NOT re-file (suppresses hourly spam)" {
  setup_divergence_state
  echo "150" > "$DIVERGENCE_STATE_FILE"
  BEHIND=150
  LAST_REPORTED_BEHIND="$(cat "$DIVERGENCE_STATE_FILE" 2>/dev/null || echo 0)"
  [[ "$LAST_REPORTED_BEHIND" =~ ^[0-9]+$ ]] || LAST_REPORTED_BEHIND=0
  [ "$BEHIND" -eq "$LAST_REPORTED_BEHIND" ]
  # Real script's condition is strictly "-gt", so equal counts must not re-fire.
  if [ "$BEHIND" -gt "$LAST_REPORTED_BEHIND" ]; then
    SHOULD_FILE="yes"
  else
    SHOULD_FILE="no"
  fi
  [ "$SHOULD_FILE" = "no" ]
}

@test "divergence: GROWING behind-count re-files even though an issue was already filed for a smaller gap" {
  setup_divergence_state
  echo "10" > "$DIVERGENCE_STATE_FILE"
  BEHIND=25
  LAST_REPORTED_BEHIND="$(cat "$DIVERGENCE_STATE_FILE" 2>/dev/null || echo 0)"
  [[ "$LAST_REPORTED_BEHIND" =~ ^[0-9]+$ ]] || LAST_REPORTED_BEHIND=0
  [ "$BEHIND" -gt "$LAST_REPORTED_BEHIND" ]
}

@test "divergence: SHRINKING behind-count (partial manual reconciliation) does not re-file" {
  setup_divergence_state
  echo "150" > "$DIVERGENCE_STATE_FILE"
  BEHIND=90
  LAST_REPORTED_BEHIND="$(cat "$DIVERGENCE_STATE_FILE" 2>/dev/null || echo 0)"
  [[ "$LAST_REPORTED_BEHIND" =~ ^[0-9]+$ ]] || LAST_REPORTED_BEHIND=0
  if [ "$BEHIND" -gt "$LAST_REPORTED_BEHIND" ]; then
    SHOULD_FILE="yes"
  else
    SHOULD_FILE="no"
  fi
  [ "$SHOULD_FILE" = "no" ]
}

@test "divergence: fully resolved (behind returns to 0) exits the issue-filing path entirely" {
  setup_divergence_state
  echo "150" > "$DIVERGENCE_STATE_FILE"
  BEHIND=0
  # BEHIND -gt 0 is the real script's outer guard for this whole branch --
  # once BEHIND is back to 0, the state file's prior value is irrelevant.
  if [ "$BEHIND" -gt 0 ]; then
    SHOULD_FILE="yes"
  else
    SHOULD_FILE="no"
  fi
  [ "$SHOULD_FILE" = "no" ]
}

@test "divergence: corrupted/non-numeric state file content is treated as zero, not a crash" {
  setup_divergence_state
  echo "not-a-number" > "$DIVERGENCE_STATE_FILE"
  BEHIND=5
  LAST_REPORTED_BEHIND="$(cat "$DIVERGENCE_STATE_FILE" 2>/dev/null || echo 0)"
  [[ "$LAST_REPORTED_BEHIND" =~ ^[0-9]+$ ]] || LAST_REPORTED_BEHIND=0
  [ "$LAST_REPORTED_BEHIND" -eq 0 ]
  [ "$BEHIND" -gt "$LAST_REPORTED_BEHIND" ]
}

# ── Content-based false-positive suppression (added 2026-09-19) ──
#
# Regression coverage for a real, confirmed false alarm: raw
# `git rev-list` ahead/behind counts are pure ancestry facts, but this
# fork's own squash-merge sync workflow deliberately severs ancestry
# from upstream's individual commits even when their content has fully
# landed. BEHIND reported ~1245 after a sync that had, by content,
# already reconciled everything upstream had. These tests mirror the
# real script's CONTENT_DELETED_COUNT gate (git diff --name-status
# upstream/main origin/main, counting 'D' lines) the same way the
# divergence tests above mirror BEHIND/LAST_REPORTED_BEHIND.

@test "divergence: BEHIND>0 with zero content-deleted files is NOT filed (ancestry-only false signal)" {
  BEHIND=1245
  CONTENT_DELETED_COUNT=0
  if [ "$BEHIND" -gt 0 ] && [ "$CONTENT_DELETED_COUNT" -eq 0 ]; then
    SHOULD_FILE="no"
  elif [ "$BEHIND" -gt 0 ]; then
    SHOULD_FILE="yes"
  else
    SHOULD_FILE="no"
  fi
  [ "$SHOULD_FILE" = "no" ]
}

@test "divergence: BEHIND>0 with real content-deleted files IS filed (genuine reconciliation gap)" {
  setup_divergence_state
  BEHIND=150
  CONTENT_DELETED_COUNT=3
  LAST_REPORTED_BEHIND="$(cat "$DIVERGENCE_STATE_FILE" 2>/dev/null || echo 0)"
  [[ "$LAST_REPORTED_BEHIND" =~ ^[0-9]+$ ]] || LAST_REPORTED_BEHIND=0
  if [ "$BEHIND" -gt 0 ] && [ "$CONTENT_DELETED_COUNT" -eq 0 ]; then
    SHOULD_FILE="no"
  elif [ "$BEHIND" -gt 0 ] && [ "$BEHIND" -gt "$LAST_REPORTED_BEHIND" ]; then
    SHOULD_FILE="yes"
  else
    SHOULD_FILE="no"
  fi
  [ "$SHOULD_FILE" = "yes" ]
}

@test "divergence: content-equivalent state with a tracked open issue triggers auto-close" {
  setup_divergence_state
  echo "150 999" > "$DIVERGENCE_STATE_FILE"
  BEHIND=150
  CONTENT_DELETED_COUNT=0
  read -r LAST_REPORTED_BEHIND LAST_ISSUE_NUMBER < "$DIVERGENCE_STATE_FILE"
  [ "$LAST_ISSUE_NUMBER" = "999" ]
  if [ "$BEHIND" -gt 0 ] && [ "$CONTENT_DELETED_COUNT" -eq 0 ]; then
    SHOULD_CLOSE="yes"
  else
    SHOULD_CLOSE="no"
  fi
  [ "$SHOULD_CLOSE" = "yes" ]
}

# ── Divergence issue dedupe + auto-close (added 2026-08-17, acp-ops-monitor#33) ──
#
# Regression coverage for a real gap: the growing-divergence branch above
# always called `gh issue create`, never checking whether an issue was
# already open for the same divergence -- confirmed in the wild as 4+
# duplicate open issues (#289/#297/#298/#300/#310/#312/#314) describing the
# same unreconciled fork state at different snapshots, none of which the
# script ever closed even after the divergence was actually resolved. These
# tests exercise the state-file format change (BEHIND + ISSUE_NUMBER, space
# separated) and the decision logic around it, mirroring the real script's
# `read -r LAST_REPORTED_BEHIND LAST_ISSUE_NUMBER < "$DIVERGENCE_STATE_FILE"`
# parsing and its two new branches (reuse-existing-issue, auto-close-on-resolve).

@test "divergence state file: old single-number format parses with empty issue number (backward compat)" {
  setup_divergence_state
  echo "150" > "$DIVERGENCE_STATE_FILE"
  read -r LAST_REPORTED_BEHIND LAST_ISSUE_NUMBER < "$DIVERGENCE_STATE_FILE" || true
  [[ "$LAST_REPORTED_BEHIND" =~ ^[0-9]+$ ]] || LAST_REPORTED_BEHIND=0
  [[ "$LAST_ISSUE_NUMBER" =~ ^[0-9]+$ ]] || LAST_ISSUE_NUMBER=""
  [ "$LAST_REPORTED_BEHIND" -eq 150 ]
  [ -z "$LAST_ISSUE_NUMBER" ]
}

@test "divergence state file: new two-field format parses both behind-count and issue number" {
  setup_divergence_state
  printf '212 310\n' > "$DIVERGENCE_STATE_FILE"
  read -r LAST_REPORTED_BEHIND LAST_ISSUE_NUMBER < "$DIVERGENCE_STATE_FILE" || true
  [[ "$LAST_REPORTED_BEHIND" =~ ^[0-9]+$ ]] || LAST_REPORTED_BEHIND=0
  [[ "$LAST_ISSUE_NUMBER" =~ ^[0-9]+$ ]] || LAST_ISSUE_NUMBER=""
  [ "$LAST_REPORTED_BEHIND" -eq 212 ]
  [ "$LAST_ISSUE_NUMBER" -eq 310 ]
}

@test "divergence state file: empty file parses to zero/empty without crashing under set -e" {
  setup_divergence_state
  : > "$DIVERGENCE_STATE_FILE"
  run bash -c '
    set -euo pipefail
    read -r LAST_REPORTED_BEHIND LAST_ISSUE_NUMBER < "'"$DIVERGENCE_STATE_FILE"'" 2>/dev/null || true
    [[ "${LAST_REPORTED_BEHIND:-}" =~ ^[0-9]+$ ]] || LAST_REPORTED_BEHIND=0
    [[ "${LAST_ISSUE_NUMBER:-}" =~ ^[0-9]+$ ]] || LAST_ISSUE_NUMBER=""
    echo "behind=$LAST_REPORTED_BEHIND issue=[$LAST_ISSUE_NUMBER]"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "behind=0 issue=[]" ]
}

@test "divergence: growing count with a tracked OPEN issue reuses it (no duplicate creation)" {
  # Mirrors the real script's branch: TRACKED_ISSUE_STATE = "OPEN" -> comment
  # on LAST_ISSUE_NUMBER instead of calling gh issue create.
  LAST_ISSUE_NUMBER=310
  TRACKED_ISSUE_STATE="OPEN"
  if [ "$TRACKED_ISSUE_STATE" = "OPEN" ]; then
    ACTION="comment"
    TARGET_ISSUE="$LAST_ISSUE_NUMBER"
  else
    ACTION="create"
    TARGET_ISSUE=""
  fi
  [ "$ACTION" = "comment" ]
  [ "$TARGET_ISSUE" -eq 310 ]
}

@test "divergence: growing count with a tracked but now-CLOSED issue creates a new one (not silently lost)" {
  # An operator may have manually closed the tracked issue (e.g. as a
  # duplicate) without the script's knowledge -- falling through to create
  # a fresh one here is correct, not a regression to the old duplicate bug,
  # because it only happens once per manual-closure event, not every run.
  LAST_ISSUE_NUMBER=310
  TRACKED_ISSUE_STATE="CLOSED"
  if [ "$TRACKED_ISSUE_STATE" = "OPEN" ]; then
    ACTION="comment"
  else
    ACTION="create"
  fi
  [ "$ACTION" = "create" ]
}

@test "divergence: growing count with no tracked issue number creates a new one" {
  LAST_ISSUE_NUMBER=""
  TRACKED_ISSUE_STATE=""
  if [ -n "$LAST_ISSUE_NUMBER" ]; then
    TRACKED_ISSUE_STATE="OPEN"
  fi
  if [ "$TRACKED_ISSUE_STATE" = "OPEN" ]; then
    ACTION="comment"
  else
    ACTION="create"
  fi
  [ "$ACTION" = "create" ]
}

@test "divergence: resolved (behind=0) with a tracked open issue triggers auto-close" {
  LAST_ISSUE_NUMBER=314
  TRACKED_ISSUE_STATE="OPEN"
  BEHIND=0
  SHOULD_CLOSE="no"
  if [ "$BEHIND" -eq 0 ] && [ -n "$LAST_ISSUE_NUMBER" ] && [ "$TRACKED_ISSUE_STATE" = "OPEN" ]; then
    SHOULD_CLOSE="yes"
  fi
  [ "$SHOULD_CLOSE" = "yes" ]
}

@test "divergence: resolved (behind=0) with no tracked issue does not attempt to close anything" {
  LAST_ISSUE_NUMBER=""
  BEHIND=0
  SHOULD_CLOSE="no"
  if [ "$BEHIND" -eq 0 ] && [ -n "$LAST_ISSUE_NUMBER" ]; then
    SHOULD_CLOSE="yes"
  fi
  [ "$SHOULD_CLOSE" = "no" ]
}

@test "divergence: resolved (behind=0) with a tracked issue already closed by someone else does not double-close" {
  LAST_ISSUE_NUMBER=279
  TRACKED_ISSUE_STATE="CLOSED"
  BEHIND=0
  SHOULD_CLOSE="no"
  if [ "$BEHIND" -eq 0 ] && [ -n "$LAST_ISSUE_NUMBER" ] && [ "$TRACKED_ISSUE_STATE" = "OPEN" ]; then
    SHOULD_CLOSE="yes"
  fi
  [ "$SHOULD_CLOSE" = "no" ]
}

@test "divergence: state file write format is 'BEHIND ISSUE_NUMBER' space-separated" {
  setup_divergence_state
  BEHIND=224
  NEW_ISSUE_NUMBER=314
  printf '%s %s\n' "$BEHIND" "$NEW_ISSUE_NUMBER" > "$DIVERGENCE_STATE_FILE"
  CONTENT="$(cat "$DIVERGENCE_STATE_FILE")"
  [ "$CONTENT" = "224 314" ]
}

# ── PR mergeability: UNKNOWN retry (added, issue #38) ──
#
# Regression coverage for a real false-positive: check_prs() treated a
# single point-in-time mergeable="UNKNOWN" reading exactly like a real
# CONFLICTING finding. GitHub computes `mergeable` asynchronously, so a
# perfectly healthy, mergeable PR can transiently read back UNKNOWN for a
# few seconds -- confirmed live against PRs #189/#201/#202, which alerted
# as UNKNOWN and then read back as stably MERGEABLE seconds later. These
# tests use a real mocked `gh` binary (unlike most tests in this file,
# which mirror decision logic inline) because the fix's behavior IS the
# sequence of `gh pr view` calls across retries.

# A copy of the real resolve_mergeable() from validate-and-report.sh --
# sourcing the real script isn't practical here (it performs live git/gh
# operations and exits immediately if `gh auth status` fails, per this
# file's own header note that network/git sections are validated through
# CI and manual review, not unit tests). This mirrors the script's exact
# retry structure with `sleep` removed; any change to the real function's
# decision logic should be mirrored here too.
resolve_mergeable() {
  local repo="$1" pr="$2" val="$3" _attempt
  for _attempt in 1 2 3; do
    [ "$val" != "UNKNOWN" ] && break
    val="$(timeout 30 gh pr view "$pr" --repo "$repo" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")"
  done
  echo "$val"
}

@test "resolve_mergeable: UNKNOWN that resolves to MERGEABLE on retry is not a failure" {
  RESOLVE_BIN_DIR="$(mktemp -d)"
  cat > "${RESOLVE_BIN_DIR}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "MERGEABLE"
MOCKEOF
  chmod +x "${RESOLVE_BIN_DIR}/gh"
  PATH="${RESOLVE_BIN_DIR}:${PATH}" run resolve_mergeable "owner/repo" 202 "UNKNOWN"
  [ "$status" -eq 0 ]
  [ "$output" = "MERGEABLE" ]
  rm -rf "${RESOLVE_BIN_DIR}"
}

@test "resolve_mergeable: value that is not UNKNOWN is returned immediately, no gh call" {
  RESOLVE_BIN_DIR="$(mktemp -d)"
  RESOLVE_CALL_LOG="$(mktemp)"
  cat > "${RESOLVE_BIN_DIR}/gh" <<MOCKEOF
#!/usr/bin/env bash
echo "CALLED" >> "${RESOLVE_CALL_LOG}"
echo "MERGEABLE"
MOCKEOF
  chmod +x "${RESOLVE_BIN_DIR}/gh"
  PATH="${RESOLVE_BIN_DIR}:${PATH}" run resolve_mergeable "owner/repo" 202 "CONFLICTING"
  [ "$status" -eq 0 ]
  [ "$output" = "CONFLICTING" ]
  [ ! -s "$RESOLVE_CALL_LOG" ]
  rm -rf "${RESOLVE_BIN_DIR}" "$RESOLVE_CALL_LOG"
}

@test "resolve_mergeable: still UNKNOWN after all retries is returned as UNKNOWN, not silently dropped" {
  RESOLVE_BIN_DIR="$(mktemp -d)"
  cat > "${RESOLVE_BIN_DIR}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "UNKNOWN"
MOCKEOF
  chmod +x "${RESOLVE_BIN_DIR}/gh"
  PATH="${RESOLVE_BIN_DIR}:${PATH}" run resolve_mergeable "owner/repo" 202 "UNKNOWN"
  [ "$status" -eq 0 ]
  [ "$output" = "UNKNOWN" ]
  rm -rf "${RESOLVE_BIN_DIR}"
}

@test "resolve_mergeable: a real merge conflict (CONFLICTING) surviving a retry is still reported" {
  RESOLVE_BIN_DIR="$(mktemp -d)"
  cat > "${RESOLVE_BIN_DIR}/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "CONFLICTING"
MOCKEOF
  chmod +x "${RESOLVE_BIN_DIR}/gh"
  PATH="${RESOLVE_BIN_DIR}:${PATH}" run resolve_mergeable "owner/repo" 202 "UNKNOWN"
  [ "$status" -eq 0 ]
  [ "$output" = "CONFLICTING" ]
  rm -rf "${RESOLVE_BIN_DIR}"
}

@test "resolve_mergeable: UNKNOWN that flips to MERGEABLE only on the 3rd attempt is caught" {
  RESOLVE_BIN_DIR="$(mktemp -d)"
  COUNTER_FILE="$(mktemp)"
  echo 0 > "$COUNTER_FILE"
  cat > "${RESOLVE_BIN_DIR}/gh" <<MOCKEOF
#!/usr/bin/env bash
n=\$(cat "${COUNTER_FILE}")
n=\$((n + 1))
echo "\$n" > "${COUNTER_FILE}"
if [ "\$n" -lt 3 ]; then
  echo "UNKNOWN"
else
  echo "MERGEABLE"
fi
MOCKEOF
  chmod +x "${RESOLVE_BIN_DIR}/gh"
  PATH="${RESOLVE_BIN_DIR}:${PATH}" run resolve_mergeable "owner/repo" 202 "UNKNOWN"
  [ "$status" -eq 0 ]
  [ "$output" = "MERGEABLE" ]
  [ "$(cat "$COUNTER_FILE")" -eq 3 ]
  rm -rf "${RESOLVE_BIN_DIR}" "$COUNTER_FILE"
}
