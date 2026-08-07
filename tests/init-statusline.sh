#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_contains() { grep -qF "$2" "$1" || fail "$1 does not contain: $2"; }

TEST_HOME="$(mktemp -d)"
trap 'chmod -R u+rwx "$TEST_HOME" 2>/dev/null || :; rm -rf "$TEST_HOME"' EXIT

CONFIG="$TEST_HOME/.config"
STATE="$TEST_HOME/.local/state"
CCS_HOME="$CONFIG/ccs"
PROFILE_DIR="$CCS_HOME/profiles"
CURRENT_LINK="$STATE/ccs/current"
mkdir -p "$PROFILE_DIR" "$(dirname "$CURRENT_LINK")"
printf 'export CCS_TEST_STATUSLINE=enabled\n' > "$PROFILE_DIR/work.env"
printf 'printf "status:enabled\\n"\n' > "$PROFILE_DIR/work.statusline"
ln -s "$PROFILE_DIR/work.env" "$CURRENT_LINK"

run_init_bash() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG" XDG_STATE_HOME="$STATE" \
    bash --noprofile --norc -c 'source "$1"' _ "$ROOT/init.sh"
}

run_init_zsh() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG" XDG_STATE_HOME="$STATE" \
    zsh -f -c 'source "$1"' _ "$ROOT/init.sh"
}

run_init_bash >/dev/null 2>&1
STATUSLINE="$CCS_HOME/statusline.sh"
[[ -x "$STATUSLINE" ]] || fail "initial statusline is not executable"
assert_contains "$STATUSLINE" '# ccs statusline for work'
assert_contains "$STATUSLINE" 'status:enabled'
first_inode="$(stat -f '%i' "$STATUSLINE")"

run_init_bash >/dev/null 2>&1
assert_eq "$(stat -f '%i' "$STATUSLINE")" "$first_inode"

printf 'printf "status:changed\\n"\n' > "$PROFILE_DIR/work.statusline"
run_init_zsh >/dev/null 2>&1
second_inode="$(stat -f '%i' "$STATUSLINE")"
[[ "$second_inode" != "$first_inode" ]] || fail "changed statusline was not replaced"
assert_contains "$STATUSLINE" 'status:changed'

readonly_home="$TEST_HOME/readonly-home"
readonly_config="$readonly_home/.config"
readonly_state="$readonly_home/.local/state"
readonly_ccs="$readonly_config/ccs"
readonly_profiles="$readonly_ccs/profiles"
readonly_current="$readonly_state/ccs/current"
mkdir -p "$readonly_profiles" "$(dirname "$readonly_current")"
printf 'export CCS_TEST_STATUSLINE=readonly\n' > "$readonly_profiles/work.env"
printf 'printf "status:readonly\\n"\n' > "$readonly_profiles/work.statusline"
ln -s "$readonly_profiles/work.env" "$readonly_current"
readonly_statusline="$readonly_ccs/statusline.sh"
printf '#!/bin/bash\n# old statusline\n' > "$readonly_statusline"
chmod 755 "$readonly_statusline"
chmod 500 "$readonly_ccs"

failure_output="$(
  HOME="$readonly_home" XDG_CONFIG_HOME="$readonly_config" XDG_STATE_HOME="$readonly_state" \
    bash --noprofile --norc -c 'source "$1"' _ "$ROOT/init.sh" 2>&1
)"
assert_eq "$failure_output" ""
assert_contains "$readonly_statusline" '# old statusline'

chmod 700 "$readonly_ccs"
rm -rf "$readonly_home"

if command -v fish >/dev/null 2>&1; then
  fish -n "$ROOT/init.fish"
fi

echo "PASS: init statusline synchronization"
