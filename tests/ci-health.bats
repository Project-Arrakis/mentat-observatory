#!/usr/bin/env bats
# ci-health.bats — Tests for lib/ci-health.sh's pure log-marker matcher.
# The rest of ci-health.sh shells out to `gh api` and is validated
# through live CI runs and manual review instead (same convention as
# validate-and-report.bats — see that file's header comment), since
# real network calls aren't unit-testable in a meaningful way here.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "$SCRIPT_DIR/lib/ci-health.sh"
}

@test "ci_health_log_has_silent_skip: detects gitleaks skip marker" {
  echo "== Gitleaks changed-file scan ==
SKIP: gitleaks is not installed." | ci_health_log_has_silent_skip
}

@test "ci_health_log_has_silent_skip: detects trivy skip marker" {
  echo "== Trivy filesystem scan ==
SKIP: trivy is not installed." | ci_health_log_has_silent_skip
}

@test "ci_health_log_has_silent_skip: detects a missing-license marker" {
  echo "[Project-Arrakis] is an organization. License key is required.
missing gitleaks license. Go grab one at gitleaks.io" | ci_health_log_has_silent_skip
}

@test "ci_health_log_has_silent_skip: does not flag a clean scan log" {
  result=0
  echo "== Gitleaks changed-file scan ==
Gitleaks changed-file scan passed.
== Trivy filesystem scan ==
Running Trivy against: .security-reports/pr-files
Security checks completed." | ci_health_log_has_silent_skip || result=$?
  [ "$result" -eq 1 ]
}

@test "ci_health_log_has_silent_skip: does not flag unrelated log content mentioning 'skip'" {
  result=0
  echo "note: skipping alert-relay-token auto-provision test: file already exists" | ci_health_log_has_silent_skip || result=$?
  [ "$result" -eq 1 ]
}

@test "ci_health_log_has_silent_skip: is case-insensitive" {
  echo "skip: GitLeaks Is NOT Installed" | ci_health_log_has_silent_skip
}


# --- accepted ("known") silent skips ---------------------------------------------------------------------

make_known_file() {
  KNOWN="$(mktemp)"
  printf '%s\n' "# comment" "" "$@" > "$KNOWN"
  export CI_HEALTH_KNOWN_SKIPS_FILE="$KNOWN"
}

@test "ci_health_known_skip: honours an unexpired entry and prints its url and expiry" {
  make_known_file "Org/repo|security-checks|https://example.test/pr/1|2026-12-31"
  CI_HEALTH_TODAY=2026-10-07 run ci_health_known_skip Org/repo security-checks
  [ "$status" -eq 0 ]
  [ "$output" = "https://example.test/pr/1 2026-12-31" ]
}

@test "ci_health_known_skip: an entry is still honoured on its expiry day and stops the day after" {
  make_known_file "Org/repo|security-checks|https://example.test/pr/1|2026-12-31"
  CI_HEALTH_TODAY=2026-12-31 run ci_health_known_skip Org/repo security-checks
  [ "$status" -eq 0 ]
  CI_HEALTH_TODAY=2027-01-01 run ci_health_known_skip Org/repo security-checks
  [ "$status" -eq 1 ]
}

@test "ci_health_known_skip: matches repo AND job exactly, ignores comments and blank lines" {
  make_known_file "Org/repo|security-checks|https://example.test/pr/1|2026-12-31"
  CI_HEALTH_TODAY=2026-10-07 run ci_health_known_skip Org/other security-checks
  [ "$status" -eq 1 ]
  CI_HEALTH_TODAY=2026-10-07 run ci_health_known_skip Org/repo gitleaks
  [ "$status" -eq 1 ]
}

@test "ci_health_known_skip: an entry without a tracking url or an expiry is not honoured" {
  make_known_file "Org/repo|security-checks||2026-12-31" "Org/repo|security-checks|https://example.test/x|"
  CI_HEALTH_TODAY=2026-10-07 run ci_health_known_skip Org/repo security-checks
  [ "$status" -eq 1 ]
}

@test "ci_health_known_skip: a missing file means nothing is known" {
  CI_HEALTH_KNOWN_SKIPS_FILE=/nonexistent/file run ci_health_known_skip Org/repo security-checks
  [ "$status" -eq 1 ]
}

# End to end through check_ci_health with a stubbed `gh`: a successful run whose security job log
# contains a fail-open marker.
stub_gh_with_silent_skip() {
  STUB_DIR="$(mktemp -d)"
  cat > "$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"{name, conclusion}"*) echo '[{"name":"security-checks","conclusion":"success"}]' ;;
  *"{id, name}"*)         echo '[{"id":7,"name":"security-checks"}]' ;;
  *"/logs"*)              echo "== Gitleaks scan ==" ; echo "SKIP: gitleaks is not installed." ;;
  *) echo "[]" ;;
esac
EOF
  chmod +x "$STUB_DIR/gh"
  export PATH="$STUB_DIR:$PATH"
}

run_check() {
  GREEN="" RED="" YELLOW="" NC="" ISSUES=0
  check_ci_health "Org/repo" "Core" || true
}

@test "check_ci_health: an unlisted silent skip is a WARN and counts as an issue" {
  stub_gh_with_silent_skip
  make_known_file
  out="$(run_check; echo "ISSUES=$ISSUES")"
  [[ "$out" == *"WARN"* ]]
  [[ "$out" == *"ISSUES=1"* ]]
}

@test "check_ci_health: a tracked, unexpired silent skip is reported but is not an issue" {
  stub_gh_with_silent_skip
  make_known_file "Org/repo|security-checks|https://example.test/pr/1|2099-01-01"
  # ISSUES must be read in the same shell that ran the check, so capture it in a file.
  GREEN="" RED="" YELLOW="" NC="" ISSUES=0
  out="$(check_ci_health Org/repo Core; echo "$ISSUES" > "$BATS_TEST_TMPDIR/issues")"
  [ "$(cat "$BATS_TEST_TMPDIR/issues")" = "0" ]
  [[ "$out" == *"known silent skip"* ]]
  [[ "$out" == *"https://example.test/pr/1"* ]]
  [[ "$out" != *"WARN"* ]]
}

@test "check_ci_health: an EXPIRED known skip warns again" {
  stub_gh_with_silent_skip
  make_known_file "Org/repo|security-checks|https://example.test/pr/1|2020-01-01"
  out="$(run_check; echo "ISSUES=$ISSUES")"
  [[ "$out" == *"WARN"* ]]
  [[ "$out" == *"ISSUES=1"* ]]
}
