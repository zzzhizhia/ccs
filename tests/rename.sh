#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCS="$ROOT/ccs.sh"
JQ_BIN="$(type -P jq)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_missing() { [[ ! -e "$1" ]] || fail "unexpected path: $1"; }
assert_contains() { grep -qF "$2" "$1" || fail "$1 does not contain: $2"; }
assert_not_contains() { ! grep -qF "$2" "$1" || fail "$1 unexpectedly contains: $2"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

# Claude profiles: rename the env file, optional statusline, and active symlink together.
CLAUDE_HOME="$(mktemp -d)"
CLAUDE_CONFIG="$CLAUDE_HOME/.config"
CLAUDE_STATE="$CLAUDE_HOME/.local/state"
PROFILE_DIR="$CLAUDE_CONFIG/ccs/profiles"
CURRENT_LINK="$CLAUDE_STATE/ccs/current"
mkdir -p "$PROFILE_DIR" "$(dirname "$CURRENT_LINK")"
printf 'export ANTHROPIC_AUTH_TOKEN="claude-secret"\n' > "$PROFILE_DIR/work.env"
printf 'printf "work-status\\n"\n' > "$PROFILE_DIR/work.statusline"
ln -s "$PROFILE_DIR/work.env" "$CURRENT_LINK"

HOME="$CLAUDE_HOME" XDG_CONFIG_HOME="$CLAUDE_CONFIG" XDG_STATE_HOME="$CLAUDE_STATE" \
  bash "$CCS" rename work team >/dev/null
assert_missing "$PROFILE_DIR/work.env"
assert_missing "$PROFILE_DIR/work.statusline"
assert_file "$PROFILE_DIR/team.env"
assert_file "$PROFILE_DIR/team.statusline"
assert_eq "$(readlink "$CURRENT_LINK")" "$PROFILE_DIR/team.env"
assert_eq "$(
  HOME="$CLAUDE_HOME" XDG_CONFIG_HOME="$CLAUDE_CONFIG" XDG_STATE_HOME="$CLAUDE_STATE" \
    bash "$CCS" current
)" "team"
assert_contains "$CLAUDE_CONFIG/ccs/statusline.sh" '# ccs statusline for team'
assert_contains "$CLAUDE_CONFIG/ccs/statusline.sh" 'work-status'

printf 'export ANTHROPIC_AUTH_TOKEN="collision"\n' > "$PROFILE_DIR/taken.env"
team_hash="$(shasum -a 256 "$PROFILE_DIR/team.env" | cut -d' ' -f1)"
if HOME="$CLAUDE_HOME" XDG_CONFIG_HOME="$CLAUDE_CONFIG" XDG_STATE_HOME="$CLAUDE_STATE" \
  bash "$CCS" rename team taken >/dev/null 2>&1; then
  fail "Claude rename overwrote an existing profile"
fi
assert_eq "$(shasum -a 256 "$PROFILE_DIR/team.env" | cut -d' ' -f1)" "$team_hash"
assert_eq "$(readlink "$CURRENT_LINK")" "$PROFILE_DIR/team.env"

printf 'export ANTHROPIC_AUTH_TOKEN="idle"\n' > "$PROFILE_DIR/idle.env"
HOME="$CLAUDE_HOME" XDG_CONFIG_HOME="$CLAUDE_CONFIG" XDG_STATE_HOME="$CLAUDE_STATE" \
  bash "$CCS" rename idle idle-renamed >/dev/null
assert_file "$PROFILE_DIR/idle-renamed.env"
assert_eq "$(readlink "$CURRENT_LINK")" "$PROFILE_DIR/team.env"

printf 'export ANTHROPIC_AUTH_TOKEN="blocked"\n' > "$PROFILE_DIR/blocked.env"
printf 'existing target binding\n' > "$PROFILE_DIR/reserved.statusline"
if HOME="$CLAUDE_HOME" XDG_CONFIG_HOME="$CLAUDE_CONFIG" XDG_STATE_HOME="$CLAUDE_STATE" \
  bash "$CCS" rename blocked reserved >/dev/null 2>&1; then
  fail "Claude rename overwrote an existing statusline binding"
fi
assert_file "$PROFILE_DIR/blocked.env"

# Codex logical providers: rename profile, active reference, fixed table, and auth snapshot.
CODEX_HOME="$(mktemp -d)"
mkdir -p "$CODEX_HOME/.codex/ccs-auth"
printf '%s\n' \
  'model_provider = "proxy"' \
  'model = "gpt-test"' \
  '' \
  '[features]' \
  'unified_exec = true' \
  '' \
  '[model_providers.proxy]' \
  'name = "Display Name Stays"' \
  'base_url = "https://proxy.example/v1"' \
  'wire_api = "responses"' \
  'requires_openai_auth = false' \
  'request_max_retries = 7' \
  '' \
  '[model_providers.proxy.extra]' \
  'note = "keep-me"' \
  '' \
  '[model_providers.proxy.auth]' \
  "command = \"$JQ_BIN\"" \
  "args = [\"-er\", \".OPENAI_API_KEY\", \"$CODEX_HOME/.codex/ccs-auth/proxy.json\"]" \
  '' \
  '[model_providers.other]' \
  'name = "Other"' \
  'base_url = "https://other.example/v1"' \
  'wire_api = "chat"' \
  'requires_openai_auth = false' \
  '' \
  '[model_providers.other.auth]' \
  "command = \"$JQ_BIN\"" \
  "args = [\"-er\", \".OPENAI_API_KEY\", \"$CODEX_HOME/.codex/ccs-auth/other.json\"]" \
  > "$CODEX_HOME/.codex/config.toml"
jq -n '{auth_mode:"chatgpt",tokens:{refresh_token:"chatgpt-refresh"}}' \
  > "$CODEX_HOME/.codex/auth.json"
jq -n --arg key 'proxy-key' '{auth_mode:"apikey",OPENAI_API_KEY:$key}' \
  > "$CODEX_HOME/.codex/ccs-auth/proxy.json"
jq -n --arg key 'other-key' '{auth_mode:"apikey",OPENAI_API_KEY:$key}' \
  > "$CODEX_HOME/.codex/ccs-auth/other.json"
: > "$CODEX_HOME/.codex/ccs-auth/.migrated-v2"
chmod 600 "$CODEX_HOME/.codex/auth.json" "$CODEX_HOME/.codex/ccs-auth/"*.json
codex_auth_hash="$(shasum -a 256 "$CODEX_HOME/.codex/auth.json" | cut -d' ' -f1)"

HOME="$CODEX_HOME" bash "$CCS" codex rename proxy gateway >/dev/null
config="$CODEX_HOME/.codex/config.toml"
gateway_profile="$CODEX_HOME/.codex/ccs-providers/gateway.toml"
other_profile="$CODEX_HOME/.codex/ccs-providers/other.toml"
assert_contains "$config" 'model_provider = "ccs"'
assert_contains "$config" '[model_providers.ccs]'
assert_contains "$config" '[model_providers.ccs.extra]'
assert_contains "$config" '[model_providers.ccs.auth]'
assert_contains "$config" 'name = "Display Name Stays"'
assert_contains "$config" 'request_max_retries = 7'
assert_contains "$config" 'note = "keep-me"'
assert_contains "$config" "$CODEX_HOME/.codex/ccs-auth/gateway.json"
assert_contains "$config" 'unified_exec = true'
assert_not_contains "$config" '[model_providers.proxy]'
assert_not_contains "$config" '[model_providers.gateway]'
assert_not_contains "$config" '[model_providers.other]'
assert_not_contains "$config" "$CODEX_HOME/.codex/ccs-auth/proxy.json"
assert_contains "$gateway_profile" '[model_providers.gateway]'
assert_contains "$gateway_profile" '[model_providers.gateway.extra]'
assert_not_contains "$gateway_profile" '[model_providers.gateway.auth]'
assert_contains "$other_profile" '[model_providers.other]'
assert_file "$CODEX_HOME/.codex/ccs-auth/gateway.json"
assert_missing "$CODEX_HOME/.codex/ccs-auth/proxy.json"
assert_eq "$(jq -r '.OPENAI_API_KEY' "$CODEX_HOME/.codex/ccs-auth/gateway.json")" "proxy-key"
assert_eq "$(HOME="$CODEX_HOME" bash "$CCS" codex current)" "gateway"
assert_eq "$(shasum -a 256 "$CODEX_HOME/.codex/auth.json" | cut -d' ' -f1)" "$codex_auth_hash"

config_hash="$(shasum -a 256 "$config" | cut -d' ' -f1)"
gateway_auth_hash="$(shasum -a 256 "$CODEX_HOME/.codex/ccs-auth/gateway.json" | cut -d' ' -f1)"
if HOME="$CODEX_HOME" bash "$CCS" codex rename gateway other >/dev/null 2>&1; then
  fail "Codex rename overwrote an existing provider"
fi
if HOME="$CODEX_HOME" bash "$CCS" codex rename openai official >/dev/null 2>&1; then
  fail "Codex rename renamed the built-in OpenAI provider"
fi
if HOME="$CODEX_HOME" bash "$CCS" codex rename gateway ccs >/dev/null 2>&1; then
  fail "Codex rename reused the fixed provider ID"
fi
assert_eq "$(shasum -a 256 "$config" | cut -d' ' -f1)" "$config_hash"
assert_eq "$(shasum -a 256 "$CODEX_HOME/.codex/ccs-auth/gateway.json" | cut -d' ' -f1)" "$gateway_auth_hash"

inactive_config_hash="$(shasum -a 256 "$config" | cut -d' ' -f1)"
HOME="$CODEX_HOME" bash "$CCS" codex rename other other-renamed >/dev/null
assert_file "$CODEX_HOME/.codex/ccs-providers/other-renamed.toml"
assert_contains "$CODEX_HOME/.codex/ccs-providers/other-renamed.toml" '[model_providers.other-renamed]'
assert_missing "$other_profile"
assert_file "$CODEX_HOME/.codex/ccs-auth/other-renamed.json"
assert_missing "$CODEX_HOME/.codex/ccs-auth/other.json"
assert_eq "$(jq -r '.OPENAI_API_KEY' "$CODEX_HOME/.codex/ccs-auth/other-renamed.json")" "other-key"
assert_eq "$(shasum -a 256 "$config" | cut -d' ' -f1)" "$inactive_config_hash"
assert_eq "$(HOME="$CODEX_HOME" bash "$CCS" codex current)" "gateway"

echo "PASS: Claude and Codex rename"
