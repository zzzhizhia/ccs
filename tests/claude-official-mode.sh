#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCS="$ROOT/ccs.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_missing() { [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected path: $1"; }
assert_contains() { grep -qF "$2" "$1" || fail "$1 does not contain: $2"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_unset() {
  local name="$1"
  if printenv "$name" >/dev/null 2>&1; then
    fail "$name remained set"
  fi
}

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
CONFIG="$TEST_HOME/.config"
STATE="$TEST_HOME/.local/state"
PROFILE_DIR="$CONFIG/ccs/profiles"
CURRENT="$STATE/ccs/current"
STATUSLINE="$CONFIG/ccs/statusline.sh"
SETTINGS="$TEST_HOME/.claude/settings.json"
CREDENTIAL="$TEST_HOME/.claude/oauth-fixture.json"
mkdir -p "$PROFILE_DIR" "$(dirname "$CURRENT")" "$(dirname "$SETTINGS")"

managed_vars=(
  ANTHROPIC_BASE_URL
  ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_MODEL
  ANTHROPIC_DEFAULT_OPUS_MODEL
  ANTHROPIC_DEFAULT_SONNET_MODEL
  ANTHROPIC_DEFAULT_HAIKU_MODEL
  CLAUDE_CODE_SUBAGENT_MODEL
  CLAUDE_CODE_EFFORT_LEVEL
  CLAUDE_CODE_ATTRIBUTION_HEADER
)

set_managed_vars() {
  local name
  for name in "${managed_vars[@]}"; do
    printf -v "$name" '%s' "stale-$name"
    export "${name?}"
  done
}

assert_managed_unset() {
  local name
  for name in "${managed_vars[@]}"; do
    assert_unset "$name"
  done
}

FULL_PROFILE="$PROFILE_DIR/full.env"
for name in "${managed_vars[@]}"; do
  printf 'export %s="profile-%s"\n' "$name" "$name" >> "$FULL_PROFILE"
done
printf 'export CUSTOM_PROVIDER_FLAG="profile-custom"\n' >> "$FULL_PROFILE"
printf '#!/bin/bash\n# ccs statusline for full\nprintf "full\\n"\n' > "$STATUSLINE"
chmod +x "$STATUSLINE"
printf '{"statusLine":{"type":"command","command":"%s"},"permissions":{"defaultMode":"ask"}}\n' \
  "$STATUSLINE" > "$SETTINGS"
printf '{"authMethod":"oauth_token","apiProvider":"firstParty"}\n' > "$CREDENTIAL"
ln -s "$FULL_PROFILE" "$CURRENT"
full_profile_hash="$(shasum -a 256 "$FULL_PROFILE" | cut -d' ' -f1)"
settings_hash="$(shasum -a 256 "$SETTINGS" | cut -d' ' -f1)"
credential_hash="$(shasum -a 256 "$CREDENTIAL" | cut -d' ' -f1)"

set_managed_vars
export CUSTOM_PROVIDER_FLAG="stale-custom"
unset_code="$(
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG" XDG_STATE_HOME="$STATE" \
    bash "$CCS" unset 2> "$TEST_HOME/full.err"
)"
eval "$unset_code"
assert_managed_unset
assert_unset CUSTOM_PROVIDER_FLAG
assert_missing "$CURRENT"
assert_eq "$(shasum -a 256 "$FULL_PROFILE" | cut -d' ' -f1)" "$full_profile_hash"
assert_eq "$(shasum -a 256 "$SETTINGS" | cut -d' ' -f1)" "$settings_hash"
assert_eq "$(shasum -a 256 "$CREDENTIAL" | cut -d' ' -f1)" "$credential_hash"
assert_contains "$STATUSLINE" '# ccs statusline — no active profile'
assert_contains "$TEST_HOME/full.err" 'official Claude mode is active'

# A sparse legacy profile still clears the complete CCS-managed variable set.
SPARSE_PROFILE="$PROFILE_DIR/sparse.env"
printf 'export ANTHROPIC_AUTH_TOKEN="sparse-token"\nexport CUSTOM_LEGACY_FLAG="legacy"\n' \
  > "$SPARSE_PROFILE"
sparse_profile_hash="$(shasum -a 256 "$SPARSE_PROFILE" | cut -d' ' -f1)"
ln -s "$SPARSE_PROFILE" "$CURRENT"
set_managed_vars
export CUSTOM_LEGACY_FLAG="stale-legacy"
unset_code="$(
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG" XDG_STATE_HOME="$STATE" \
    bash "$CCS" unset 2>/dev/null
)"
eval "$unset_code"
assert_managed_unset
assert_unset CUSTOM_LEGACY_FLAG
assert_eq "$(shasum -a 256 "$SPARSE_PROFILE" | cut -d' ' -f1)" "$sparse_profile_hash"

# A dangling active link and no active profile both clear stale managed values.
ln -s "$PROFILE_DIR/missing.env" "$CURRENT"
set_managed_vars
unset_code="$(
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG" XDG_STATE_HOME="$STATE" \
    bash "$CCS" unset 2>/dev/null
)"
eval "$unset_code"
assert_managed_unset
assert_missing "$CURRENT"

set_managed_vars
unset_code="$(
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG" XDG_STATE_HOME="$STATE" \
    bash "$CCS" unset 2>/dev/null
)"
eval "$unset_code"
assert_managed_unset

# Fish receives native variable-erasure statements from the same command.
fish_code="$(
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$CONFIG" XDG_STATE_HOME="$STATE" CCS_SHELL=fish \
    bash "$CCS" unset 2>/dev/null
)"
grep -qE '^set -e ANTHROPIC_BASE_URL$' <<< "$fish_code" \
  || fail "fish output did not erase ANTHROPIC_BASE_URL"
if grep -qE '^unset[[:space:]]' <<< "$fish_code"; then
  fail "fish output used POSIX unset syntax"
fi
assert_contains "$ROOT/init.fish" 'env CCS_SHELL=fish command ccs.sh'
assert_file "$FULL_PROFILE"
assert_file "$SPARSE_PROFILE"

echo "PASS: Claude official subscription mode"
