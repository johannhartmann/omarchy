#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export TEST_LOG="$test_tmp/events"
mkdir -p "$test_tmp/bin" "$test_tmp/home/Work"

for command in omarchy-launch-tui omarchy-agent-usage-update omarchy-shell mise agy omarchy-pkg-aur-add omarchy-pkg-drop uwsm-app; do
  cat >"$test_tmp/bin/$command" <<'SH'
#!/bin/bash
name=${0##*/}
printf '%s:%s\n' "$name" "$*" >>"$TEST_LOG"
if [[ $name == "agy" ]]; then exit "${TEST_AGY_EXIT:-0}"; fi
if [[ $name == "omarchy-pkg-aur-add" ]]; then exit "${TEST_INSTALL_EXIT:-0}"; fi
SH
done
cat >"$test_tmp/bin/omarchy-cmd-missing" <<'SH'
#!/bin/bash
[[ ${TEST_NEEDS_INSTALL:-0} == 1 ]]
SH
cat >"$test_tmp/bin/omarchy-mise-default-tools" <<'SH'
#!/bin/bash
[[ $1 == "declares" && $2 == "antigravity-cli" ]]
SH
cat >"$test_tmp/bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
chmod +x "$test_tmp/bin/"*

run_command() {
  HOME="$test_tmp/home" PATH="$test_tmp/bin:$PATH" OMARCHY_PATH="$ROOT" "$ROOT/bin/$1" "${@:2}"
}

run_command omarchy-agent-signin-agy
grep -qx 'omarchy-launch-tui:--app-id=org.omarchy.agent omarchy-agent-signin-agy --inline' "$TEST_LOG" || fail "native sign-in opens an agent terminal"
pass "native sign-in opens an agent terminal"

: >"$TEST_LOG"
TEST_NEEDS_INSTALL=1 run_command omarchy-agent-signin-agy --inline >"$test_tmp/signin.log"
[[ $(cat "$TEST_LOG") == $'mise:install antigravity-cli\nagy:\nomarchy-agent-usage-update:--force agy\nomarchy-shell:-q omarchy.agents refresh' ]] || fail "sign-in installs declared CLI and refreshes after native onboarding" "$(cat "$TEST_LOG")"
pass "sign-in uses native onboarding without auto-approval or changing the default"

: >"$TEST_LOG"
if TEST_AGY_EXIT=7 run_command omarchy-agent-signin-agy --inline >"$test_tmp/signin-failed.log"; then
  fail "native sign-in propagates CLI failure"
else
  [[ $? == 7 ]] || fail "native sign-in preserves CLI exit code"
fi
grep -qx 'omarchy-agent-usage-update:--force agy' "$TEST_LOG" || fail "failed sign-in still refreshes usage"
pass "failed native sign-in preserves its exit status and refreshes usage"

: >"$TEST_LOG"
if run_command omarchy-agent-signin-agy --inline unexpected >"$test_tmp/invalid.log" 2>&1; then fail "sign-in rejects invalid arguments"; fi
[[ ! -s $TEST_LOG ]] || fail "invalid sign-in arguments never launch a CLI"
pass "invalid sign-in arguments never launch a CLI"

: >"$TEST_LOG"
if TEST_INSTALL_EXIT=4 run_command omarchy-install-ai-antigravity >"$test_tmp/install-failed.log"; then fail "desktop installation reports package failures"; fi
[[ $(cat "$TEST_LOG") == 'omarchy-pkg-aur-add:antigravity' ]] || fail "failed desktop installation never launches the app"
pass "failed desktop installation never launches the app"

: >"$TEST_LOG"
run_command omarchy-install-ai-antigravity >"$test_tmp/install.log"
for (( attempt=0; attempt<100; attempt++ )); do
  grep -q '^uwsm-app:' "$TEST_LOG" && break
  sleep 0.01
done
[[ $(cat "$TEST_LOG") == $'omarchy-pkg-aur-add:antigravity\nuwsm-app:-- /usr/bin/antigravity' ]] || fail "desktop installation launches the packaged app" "$(cat "$TEST_LOG")"
pass "desktop installation launches the packaged app"

mkdir -p "$test_tmp/home/.gemini/antigravity-cli/brain" "$test_tmp/home/.local/bin" "$test_tmp/home/.config/Antigravity"
for file in .gemini/signin .gemini/antigravity-cli/brain/conversation .local/bin/agy .config/Antigravity/settings; do
  printf 'keep\n' >"$test_tmp/home/$file"
done
: >"$TEST_LOG"
run_command omarchy-remove-ai-antigravity >"$test_tmp/remove.log"
[[ $(cat "$TEST_LOG") == 'omarchy-pkg-drop:antigravity' ]] || fail "desktop removal only removes the desktop package"
for file in .gemini/signin .gemini/antigravity-cli/brain/conversation .local/bin/agy .config/Antigravity/settings; do
  [[ $(cat "$test_tmp/home/$file") == "keep" ]] || fail "desktop removal preserves shared data and CLI"
done
pass "desktop removal preserves shared data and CLI"
