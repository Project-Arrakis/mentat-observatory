#!/usr/bin/env bats
# tests/all-clear.bats — the all-clear message must not say "synced" while the
# Core fork is behind upstream (mentat-observatory#59).
#
# Run with: bats tests/all-clear.bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/all-clear.sh"
}

@test "behind upstream never says synced, even when already reported" {
  run all_clear_message 5 2 0
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"Fork Behind Upstream"* ]]
  [[ "${lines[1]}" == *"5 commit(s) behind"* ]]
  [[ "$output" != *"Core fork synced"* ]]
}

@test "synced with no open issues keeps the plain all-clear" {
  run all_clear_message 0 0 3
  [[ "${lines[0]}" == "✅ ACP Validation — All Clear" ]]
  [[ "${lines[1]}" == *"Core fork synced"* ]]
  [[ "${lines[1]}" == *"3 PR events"* ]]
}

@test "synced but open ops-monitor issues are mentioned" {
  run all_clear_message 0 2 0
  [[ "${lines[0]}" == *"open issues remain"* ]]
  [[ "${lines[1]}" == *"2 open ops-monitor issue(s)"* ]]
}

@test "unreadable issue count is stated, not hidden" {
  run all_clear_message 0 '?' 0
  [[ "$output" == *"count unavailable"* ]]
}

@test "non-numeric behind count is treated as zero" {
  run all_clear_message abc 0 0
  [[ "${lines[0]}" == "✅ ACP Validation — All Clear" ]]
}
