#!/usr/bin/env bats
# tests/notify-discord.bats — Regression coverage for notify-discord.sh,
# in particular the color-override bug fixed 2026-07-24 (see the BUG FIX
# comment in notify-discord.sh): the event->color lookup table used to
# unconditionally clobber an explicitly-passed color argument, so every
# "deploy" event (used by validate-and-report.sh for all of its
# success/resolved/issue notifications) rendered red in Discord regardless
# of actual outcome.
#
# These tests stub curl so no real network call or webhook is required.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../notify-discord.sh"
  TEST_BIN_DIR="$(mktemp -d)"
  # Stub curl: capture the payload it was given instead of sending it.
  cat > "${TEST_BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
# Find the -d argument (the JSON payload) and dump it to CAPTURED_PAYLOAD_FILE.
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "-d" ]; then
    j=$((i+1))
    echo "${!j}" > "${CAPTURED_PAYLOAD_FILE}"
  fi
done
exit 0
EOF
  chmod +x "${TEST_BIN_DIR}/curl"
  export PATH="${TEST_BIN_DIR}:${PATH}"
  export CAPTURED_PAYLOAD_FILE="$(mktemp)"
  export DISCORD_DEV_WEBHOOK_URL="https://discord.example.com/api/webhooks/000/fake-for-tests"
}

teardown() {
  rm -rf "${TEST_BIN_DIR}" "${CAPTURED_PAYLOAD_FILE}"
}

payload_color() {
  python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['embeds'][0]['color'])" "${CAPTURED_PAYLOAD_FILE}"
}

@test "explicit color argument is respected for the deploy event (green)" {
  run bash "$SCRIPT" deploy "Title" "Desc" "" 5763719
  [ "$status" -eq 0 ]
  [ "$(payload_color)" = "5763719" ]
}

@test "explicit color argument is respected for the deploy event (red)" {
  run bash "$SCRIPT" deploy "Title" "Desc" "" 16744192
  [ "$status" -eq 0 ]
  [ "$(payload_color)" = "16744192" ]
}

@test "deploy event without explicit color falls back to the red default" {
  run bash "$SCRIPT" deploy "Title" "Desc"
  [ "$status" -eq 0 ]
  [ "$(payload_color)" = "10181046" ]
}

@test "pr-merged event without explicit color uses its own default (green)" {
  run bash "$SCRIPT" pr-merged "Title" "Desc"
  [ "$status" -eq 0 ]
  [ "$(payload_color)" = "3066993" ]
}

@test "unknown event without explicit color defaults to 0" {
  run bash "$SCRIPT" some-unknown-event "Title" "Desc"
  [ "$status" -eq 0 ]
  [ "$(payload_color)" = "0" ]
}

@test "unknown event WITH explicit color respects the explicit value" {
  run bash "$SCRIPT" some-unknown-event "Title" "Desc" "" 42
  [ "$status" -eq 0 ]
  [ "$(payload_color)" = "42" ]
}

@test "missing event or title exits non-zero with usage message" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "missing webhook URL exits 0 (soft-fail, does not break calling cron job)" {
  unset DISCORD_DEV_WEBHOOK_URL
  # Isolate HOME so the script's WEBHOOK_FILE fallback path can't
  # accidentally pick up a real webhook file present on the dev machine.
  ISOLATED_HOME="$(mktemp -d)"
  run env HOME="$ISOLATED_HOME" DISCORD_DEV_WEBHOOK_URL= bash "$SCRIPT" deploy "Title" "Desc"
  rm -rf "$ISOLATED_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Discord webhook URL found"* ]]
}

@test "title and description are passed through into the payload" {
  run bash "$SCRIPT" deploy "My Title" "My Description" "" 123
  [ "$status" -eq 0 ]
  python3 -c "
import json
d = json.load(open('${CAPTURED_PAYLOAD_FILE}'))
assert d['embeds'][0]['title'] == 'My Title', d
assert d['embeds'][0]['description'] == 'My Description', d
"
}

# --- Voice: the Mentat (Sahir Venn) speaks for the hourly "Projection" job -----------------------------

payload_field() {
  python3 -c "
import json,sys
p=json.load(open(sys.argv[1]))
path=sys.argv[2].split('.')
v=p
for k in path:
    v=v[0] if k=='0' else v[k]
print(v)" "${CAPTURED_PAYLOAD_FILE}" "$1"
}

@test "messages come from the Mentat, not the old ACP bot" {
  run bash "$SCRIPT" deploy "Title" "Desc" "" 5763719
  [ "$status" -eq 0 ]
  [ "$(payload_field username)" = "Sahir Venn" ]
  ! grep -qi "ACP" "${CAPTURED_PAYLOAD_FILE}"
}

@test "the default avatar is the Mentat bot icon hosted in the public mentat repo" {
  run bash "$SCRIPT" deploy "Title" "Desc"
  [ "$status" -eq 0 ]
  [ "$(payload_field avatar_url)" = "https://raw.githubusercontent.com/Project-Arrakis/mentat/main/assets/bot-icon-256.png" ]
}

@test "hourly events carry the Projection footer" {
  for event in deploy upstream-pr-created upstream-pr-merged pr-merged; do
    run bash "$SCRIPT" "$event" "Title" "Desc"
    [ "$status" -eq 0 ]
    [ "$(payload_field embeds.0.footer.text)" = "Projection · the Mentat's hourly computation" ]
  done
}

@test "manual pipeline events carry the development-pipeline footer, not the hourly one" {
  for event in branch-created pr-created; do
    run bash "$SCRIPT" "$event" "Title" "Desc"
    [ "$status" -eq 0 ]
    [ "$(payload_field embeds.0.footer.text)" = "Mentat · development pipeline" ]
  done
}

@test "sender, avatar and footer can be overridden per host" {
  NOTIFY_SENDER_NAME="Thufir" NOTIFY_AVATAR_URL="https://example.test/a.png" NOTIFY_FOOTER_TEXT="custom footer" \
    run bash "$SCRIPT" deploy "Title" "Desc"
  [ "$status" -eq 0 ]
  [ "$(payload_field username)" = "Thufir" ]
  [ "$(payload_field avatar_url)" = "https://example.test/a.png" ]
  [ "$(payload_field embeds.0.footer.text)" = "custom footer" ]
}

@test "an override containing quotes and shell syntax is passed through as data and never executed" {
  marker="$(mktemp -u)"
  NOTIFY_SENDER_NAME="O'Brien \"x\" \$(touch ${marker}) \`touch ${marker}\`" \
    run bash "$SCRIPT" deploy "Title" "Desc"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  [[ "$(payload_field username)" == *'$(touch'* ]]
}
