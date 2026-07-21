#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCS="$ROOT/ccs.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_contains() { grep -qF "$2" "$1" || fail "$1 does not contain: $2"; }
assert_not_contains() { ! grep -qF "$2" "$1" || fail "$1 unexpectedly contains: $2"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

# Fresh file-mode workflow, including preservation of unrelated config and ChatGPT auth.
TEST_HOME="$(mktemp -d)"
mkdir -p "$TEST_HOME/.codex"
printf '%s\n' \
  'model = "gpt-test"' \
  'model_reasoning_effort = "high"' \
  '' \
  '[features]' \
  'unified_exec = true' > "$TEST_HOME/.codex/config.toml"
jq -n '{auth_mode:"chatgpt",OPENAI_API_KEY:null,tokens:{access_token:"access",refresh_token:"refresh"}}' \
  > "$TEST_HOME/.codex/auth.json"
chmod 600 "$TEST_HOME/.codex/auth.json"

HOME="$TEST_HOME" bash "$CCS" codex list >/dev/null
assert_file "$TEST_HOME/.codex/ccs-auth/openai.json"
assert_eq "$(jq -r '.tokens.refresh_token' "$TEST_HOME/.codex/ccs-auth/openai.json")" "refresh"

printf '\nhttps://proxy.example/v1\n\nproxy-key\n' \
  | HOME="$TEST_HOME" bash "$CCS" codex new proxy >/dev/null
assert_contains "$TEST_HOME/.codex/config.toml" '[model_providers.proxy]'
assert_contains "$TEST_HOME/.codex/config.toml" 'requires_openai_auth = true'
assert_not_contains "$TEST_HOME/.codex/config.toml" 'env_key ='
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "proxy-key"
assert_eq "$(stat -f '%Lp' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "600"
assert_eq "$(stat -f '%Lp' "$TEST_HOME/.codex/ccs-auth")" "700"

HOME="$TEST_HOME" bash "$CCS" codex use proxy >/dev/null
assert_contains "$TEST_HOME/.codex/config.toml" 'model_provider = "proxy"'
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/auth.json")" "proxy-key"
assert_contains "$TEST_HOME/.codex/config.toml" 'model = "gpt-test"'
assert_contains "$TEST_HOME/.codex/config.toml" 'unified_exec = true'
if CODEX_BIN="$(type -P codex 2>/dev/null)" && [[ -n "$CODEX_BIN" ]]; then
  CODEX_HOME="$TEST_HOME/.codex" "$CODEX_BIN" login status 2>&1 | grep -qi 'API key' \
    || fail "real Codex CLI did not accept generated API-key auth"
fi

HOME="$TEST_HOME" bash "$CCS" codex use openai >/dev/null
assert_eq "$(jq -r '.tokens.refresh_token' "$TEST_HOME/.codex/auth.json")" "refresh"
assert_eq "$(HOME="$TEST_HOME" bash "$CCS" codex current)" "openai"

printf '\nhttps://proxy.example/v2\n\nproxy-key-2\n' \
  | HOME="$TEST_HOME" bash "$CCS" codex edit proxy >/dev/null
assert_contains "$TEST_HOME/.codex/config.toml" 'base_url = "https://proxy.example/v2"'
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "proxy-key-2"
show_output="$(HOME="$TEST_HOME" bash "$CCS" codex show proxy)"
[[ "$show_output" == *'api_key:  ***'* ]] || fail "show did not mask API key"
[[ "$show_output" != *'proxy-key-2'* ]] || fail "show leaked API key"

# Duplicate creation, removed commands, corrupt snapshots, and lock contention fail safely.
if HOME="$TEST_HOME" bash "$CCS" codex new proxy >/dev/null 2>&1; then
  fail "duplicate provider creation succeeded"
fi
if HOME="$TEST_HOME" bash "$CCS" codex env proxy >/dev/null 2>&1; then
  fail "removed env command succeeded"
fi
config_hash="$(shasum -a 256 "$TEST_HOME/.codex/config.toml" | cut -d' ' -f1)"
auth_hash="$(shasum -a 256 "$TEST_HOME/.codex/auth.json" | cut -d' ' -f1)"
mkdir "$TEST_HOME/.codex/.ccs.lock"
if HOME="$TEST_HOME" bash "$CCS" codex use proxy >/dev/null 2>&1; then
  fail "switch succeeded while lock was held"
fi
rmdir "$TEST_HOME/.codex/.ccs.lock"
assert_eq "$(shasum -a 256 "$TEST_HOME/.codex/config.toml" | cut -d' ' -f1)" "$config_hash"
assert_eq "$(shasum -a 256 "$TEST_HOME/.codex/auth.json" | cut -d' ' -f1)" "$auth_hash"
printf '{broken\n' > "$TEST_HOME/.codex/ccs-auth/proxy.json"
if HOME="$TEST_HOME" bash "$CCS" codex use proxy >/dev/null 2>&1; then
  fail "switch succeeded with corrupt auth snapshot"
fi
assert_eq "$(shasum -a 256 "$TEST_HOME/.codex/config.toml" | cut -d' ' -f1)" "$config_hash"
assert_eq "$(shasum -a 256 "$TEST_HOME/.codex/auth.json" | cut -d' ' -f1)" "$auth_hash"
jq -n --arg key 'proxy-key-2' '{auth_mode:"apikey",OPENAI_API_KEY:$key}' > "$TEST_HOME/.codex/ccs-auth/proxy.json"
chmod 600 "$TEST_HOME/.codex/ccs-auth/proxy.json"

HOME="$TEST_HOME" bash "$CCS" codex use proxy >/dev/null
if printf 'y\n' | HOME="$TEST_HOME" bash "$CCS" codex rm proxy >/dev/null 2>&1; then
  fail "removed active provider"
fi
HOME="$TEST_HOME" bash "$CCS" codex use openai >/dev/null
printf 'y\n' | HOME="$TEST_HOME" bash "$CCS" codex rm proxy >/dev/null
assert_not_contains "$TEST_HOME/.codex/config.toml" '[model_providers.proxy]'
[[ ! -e "$TEST_HOME/.codex/ccs-auth/proxy.json" ]] || fail "proxy auth snapshot still exists"

# v0.2 migration: preserve ChatGPT, import API key, restore the formerly active provider.
MIGRATE_HOME="$(mktemp -d)"
mkdir -p "$MIGRATE_HOME/.codex" "$MIGRATE_HOME/.config/ccs/codex/profiles" "$MIGRATE_HOME/.local/state/ccs/codex"
printf '%s\n' \
  'model = "gpt-test"' \
  '' \
  '[model_providers.of]' \
  'name = "of"' \
  'base_url = "https://of.example/v1"' \
  'wire_api = "responses"' \
  'env_key = "OPENAI_API_KEY"' \
  'request_max_retries = 7' > "$MIGRATE_HOME/.codex/config.toml"
jq -n '{auth_mode:"chatgpt",OPENAI_API_KEY:null,tokens:{refresh_token:"chatgpt-refresh"}}' \
  > "$MIGRATE_HOME/.codex/auth.json"
printf '%s\n' \
  'export CCS_CODEX_PROVIDER="of"' \
  'export OPENAI_API_KEY="legacy-key"' > "$MIGRATE_HOME/.config/ccs/codex/profiles/of.env"
ln -s "$MIGRATE_HOME/.config/ccs/codex/profiles/of.env" "$MIGRATE_HOME/.local/state/ccs/codex/current"

assert_eq "$(HOME="$MIGRATE_HOME" bash "$CCS" codex current 2>/dev/null)" "of"
assert_eq "$(jq -r '.OPENAI_API_KEY' "$MIGRATE_HOME/.codex/auth.json")" "legacy-key"
assert_eq "$(jq -r '.tokens.refresh_token' "$MIGRATE_HOME/.codex/ccs-auth/openai.json")" "chatgpt-refresh"
assert_not_contains "$MIGRATE_HOME/.codex/config.toml" 'env_key ='
assert_contains "$MIGRATE_HOME/.codex/config.toml" 'requires_openai_auth = true'
assert_contains "$MIGRATE_HOME/.codex/config.toml" 'request_max_retries = 7'
assert_file "$MIGRATE_HOME/.codex/ccs-auth/.migrated-v1"
compgen -G "$MIGRATE_HOME/.config/ccs/codex/profiles.migrated-*" >/dev/null \
  || fail "legacy profiles backup missing"
assert_eq "$(HOME="$MIGRATE_HOME" bash "$CCS" codex current 2>/dev/null)" "of"

# A brand-new user can create an official subscription credential through the native login.
NEW_USER_HOME="$(mktemp -d)"
FAKE_BIN="$(mktemp -d)"
cp "$ROOT/tests/fixtures/codex" "$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/codex"
HOME="$NEW_USER_HOME" PATH="$FAKE_BIN:$PATH" bash "$CCS" codex new openai >/dev/null
assert_eq "$(jq -r '.auth_mode' "$NEW_USER_HOME/.codex/auth.json")" "chatgpt"
assert_eq "$(jq -r '.tokens.refresh_token' "$NEW_USER_HOME/.codex/ccs-auth/openai.json")" "native-refresh"
assert_eq "$(HOME="$NEW_USER_HOME" bash "$CCS" codex current)" "openai"
assert_eq "$(stat -f '%Lp' "$NEW_USER_HOME/.codex/ccs-auth/openai.json")" "600"
if HOME="$NEW_USER_HOME" PATH="$FAKE_BIN:$PATH" bash "$CCS" codex new openai >/dev/null 2>&1; then
  fail "duplicate OpenAI subscription creation succeeded"
fi
HOME="$NEW_USER_HOME" PATH="$FAKE_BIN:$PATH" bash "$CCS" codex login >/dev/null
assert_eq "$(jq -r '.tokens.account_id' "$NEW_USER_HOME/.codex/ccs-auth/openai.json")" "native-account"

# Initialization must not wrap Codex or restore Codex environment profiles.
assert_not_contains "$ROOT/init.sh" 'codex()'
assert_not_contains "$ROOT/init.sh" 'CCS_CODEX'
assert_not_contains "$ROOT/init.fish" 'function codex'
assert_not_contains "$ROOT/init.fish" 'CCS_CODEX'

echo "PASS: Codex file-mode integration"
