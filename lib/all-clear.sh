#!/usr/bin/env bash
# lib/all-clear.sh — wording for the "no new issues" Discord message.
#
# The old message was a fixed string ("Core fork synced. ... CI clean."),
# posted whenever a run found no NEW issue. Step 1 treats a fork that is
# behind upstream but already has a tracking issue as OK ("already reported,
# no growth"), so on 2026-10-22 the 09:03 message said "Core fork synced"
# while main was 5 commits behind upstream v1.4.52 with #1243/#1244 open
# (mentat-observatory#59). Taking the state as arguments keeps the wording
# unit-testable without gh or git.

# all_clear_message <behind_real> <open_ops_issues> <activity>
#   behind_real      commits the Core fork is genuinely behind upstream
#                    (0 when synced or when only ancestry differs)
#   open_ops_issues  open `ops-monitor` issues on the Core fork, or "?" if
#                    the count could not be read
#   activity         number of PR events this run
#
# Prints two lines: the Discord title, then the body.
all_clear_message() {
  local behind="${1:-0}" open="${2:-0}" activity="${3:-0}"
  [[ "$behind" =~ ^[0-9]+$ ]] || behind=0
  if [ "$behind" -gt 0 ]; then
    printf '%s\n' "⚠️ ACP Validation — No New Issues, Fork Behind Upstream"
    printf '%s\n' "Core fork is ${behind} commit(s) behind upstream (already tracked; open ops-monitor issues: ${open}). All PRs MERGEABLE. CI clean. ${activity} PR events detected."
  elif [ "$open" = "?" ]; then
    printf '%s\n' "✅ ACP Validation — All Clear"
    printf '%s\n' "Core fork synced. All PRs MERGEABLE. CI clean. ${activity} PR events detected. (Open ops-monitor issue count unavailable this run.)"
  elif [[ "$open" =~ ^[0-9]+$ ]] && [ "$open" -gt 0 ]; then
    printf '%s\n' "✅ ACP Validation — All Clear (open issues remain)"
    printf '%s\n' "Core fork synced. All PRs MERGEABLE. CI clean. ${open} open ops-monitor issue(s) on Core still need triage. ${activity} PR events detected."
  else
    printf '%s\n' "✅ ACP Validation — All Clear"
    printf '%s\n' "Core fork synced. All PRs MERGEABLE. CI clean. ${activity} PR events detected."
  fi
}
