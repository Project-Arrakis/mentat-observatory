#!/usr/bin/env bats
# timeouts.bats -- network wrappers must bound a hung call (#17, #56).

setup() {
  TEST_DIR="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$TEST_DIR/gh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$TEST_DIR/curl"
  chmod +x "$TEST_DIR/gh" "$TEST_DIR/curl"
  export PATH="$TEST_DIR:$PATH"
}
teardown() { rm -rf "$TEST_DIR"; }

@test "timeouts: a hung gh call is killed and returns 124" {
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/timeouts.sh'; ACP_NET_TIMEOUT=1 gh api x"
  [ "$status" -eq 124 ]
}

@test "timeouts: a normal curl call passes through with output and args" {
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/timeouts.sh'; curl -s http://x"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "timeouts: a hung git fetch is killed (124), a local git command is not wrapped" {
  printf '#!/usr/bin/env bash\n[ "$1" = fetch ] && exec sleep 30\necho local-ok\n' > "$TEST_DIR/git"
  chmod +x "$TEST_DIR/git"
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/timeouts.sh'; ACP_GIT_TIMEOUT=1 git fetch origin"
  [ "$status" -eq 124 ]
  run bash -c "source '$BATS_TEST_DIRNAME/../lib/timeouts.sh'; git status"
  [ "$output" = "local-ok" ]
}

@test "timeouts: both scripts source the wrapper before their first network call" {
  for f in validate-and-report.sh check-upstream-prs.sh; do
    src=$(grep -n '^source .*timeouts.sh' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
    first=$(grep -n -E '^[[:space:]]*(if ! )?(gh|git (fetch|push)|curl) ' "$BATS_TEST_DIRNAME/../$f" | head -1 | cut -d: -f1)
    [ -n "$src" ] && [ -n "$first" ] && [ "$src" -lt "$first" ]
  done
}

@test "notify-discord.sh bounds its own curl" {
  grep -q -- '--max-time' "$BATS_TEST_DIRNAME/../notify-discord.sh"
}
