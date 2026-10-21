#!/usr/bin/env bats
# timeouts.bats -- gh/curl wrappers must bound a hung call (#17).

setup() {
  TEST_DIR="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$TEST_DIR/gh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$TEST_DIR/curl"
  chmod +x "$TEST_DIR/gh" "$TEST_DIR/curl"
  export PATH="$TEST_DIR:$PATH"
}
teardown() { rm -rf "$TEST_DIR"; }

@test "timeouts: a hung gh call is killed and returns 124" {
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/timeouts.sh'; ACP_NET_TIMEOUT=1 gh api x"
  [ "$status" -eq 124 ]
}

@test "timeouts: a normal call passes through with its output and args" {
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/timeouts.sh'; curl -s http://x"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "timeouts: both scripts source the wrapper" {
  grep -q 'lib/timeouts.sh' "$BATS_TEST_DIRNAME/../validate-and-report.sh"
  grep -q 'lib/timeouts.sh' "$BATS_TEST_DIRNAME/../check-upstream-prs.sh"
}
