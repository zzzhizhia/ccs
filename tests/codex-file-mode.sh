#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCS="$ROOT/ccs.sh"
JQ_BIN="$(type -P jq)"
EDITOR_FIXTURE="$ROOT/tests/fixtures/codex-provider-editor"
EDITOR_CMD="bash $EDITOR_FIXTURE"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_contains() { grep -qF "$2" "$1" || fail "$1 does not contain: $2"; }
assert_not_contains() { ! grep -qF "$2" "$1" || fail "$1 unexpectedly contains: $2"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_no_ccs_temps() {
  local leftover
  leftover="$(
    find "$1/.codex" "$1/.codex/ccs-auth" -maxdepth 1 -type f -name '.ccs.*' -print -quit 2>/dev/null
  )"
  [[ -z "$leftover" ]] || fail "temporary CCS file was not cleaned up: $leftover"
}

# Fresh file-mode workflow, including preservation of unrelated config and ChatGPT auth.
TEST_HOME="$(mktemp -d)"
mkdir -p "$TEST_HOME/.codex"
printf '%s\n' \
  'model = "gpt-test"' \
  'model_reasoning_effort = "high"' \
  '' \
  '[features]' \
  'unified_exec = true' > "$TEST_HOME/.codex/config.toml"
jq -n '{
  auth_mode:"chatgpt",
  OPENAI_API_KEY:null,
  tokens:{
    access_token:"e30.eyJzdWIiOiJ1c2VyIn0.sig",
    id_token:"e30.eyJzdWIiOiJ1c2VyIiwiZW1haWwiOiJ0ZXN0QGV4YW1wbGUuY29tIn0.sig",
    refresh_token:"refresh",
    account_id:"account"
  }
}' \
  > "$TEST_HOME/.codex/auth.json"
chmod 600 "$TEST_HOME/.codex/auth.json"
chatgpt_auth_hash="$(shasum -a 256 "$TEST_HOME/.codex/auth.json" | cut -d' ' -f1)"

HOME="$TEST_HOME" bash "$CCS" codex list >/dev/null
assert_eq "$(bash "$CCS" version)" "ccs 0.5.0"
assert_file "$TEST_HOME/.codex/ccs-auth/openai.json"
assert_eq "$(jq -r '.tokens.refresh_token' "$TEST_HOME/.codex/ccs-auth/openai.json")" "refresh"
assert_file "$TEST_HOME/.codex/ccs-auth/.migrated-v2"

printf 'proxy-key\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" \
    CCS_TEST_DISPLAY_NAME="Proxy via editor" \
    CCS_TEST_BASE_URL="https://proxy.example/v1" \
    CCS_TEST_RETRY_COUNT=7 \
    bash "$CCS" codex new proxy >/dev/null
assert_contains "$TEST_HOME/.codex/config.toml" '[model_providers.proxy]'
assert_contains "$TEST_HOME/.codex/config.toml" 'name = "Proxy via editor"'
assert_contains "$TEST_HOME/.codex/config.toml" 'request_max_retries = 7'
assert_contains "$TEST_HOME/.codex/config.toml" 'requires_openai_auth = false'
assert_not_contains "$TEST_HOME/.codex/config.toml" 'env_key ='
assert_not_contains "$TEST_HOME/.codex/config.toml" 'proxy-key'
assert_contains "$TEST_HOME/.codex/config.toml" '[model_providers.proxy.auth]'
assert_contains "$TEST_HOME/.codex/config.toml" "command = \"$JQ_BIN\""
assert_contains "$TEST_HOME/.codex/config.toml" \
  "args = [\"-er\", \".OPENAI_API_KEY | strings | select(length > 0)\", \"$TEST_HOME/.codex/ccs-auth/proxy.json\"]"
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "proxy-key"
assert_eq "$("$JQ_BIN" -er '.OPENAI_API_KEY | strings | select(length > 0)' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "proxy-key"
assert_eq "$(jq -r '.tokens.refresh_token' "$TEST_HOME/.codex/auth.json")" "refresh"
assert_eq "$(stat -f '%Lp' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "600"
assert_eq "$(stat -f '%Lp' "$TEST_HOME/.codex/ccs-auth")" "700"

HOME="$TEST_HOME" bash "$CCS" codex use proxy >/dev/null
assert_contains "$TEST_HOME/.codex/config.toml" 'model_provider = "proxy"'
assert_eq "$(jq -r '.auth_mode' "$TEST_HOME/.codex/auth.json")" "chatgpt"
assert_eq "$(jq -r '.tokens.refresh_token' "$TEST_HOME/.codex/auth.json")" "refresh"
assert_contains "$TEST_HOME/.codex/config.toml" 'model = "gpt-test"'
assert_contains "$TEST_HOME/.codex/config.toml" 'unified_exec = true'
if CODEX_BIN="$(type -P codex 2>/dev/null)" && [[ -n "$CODEX_BIN" ]]; then
  CODEX_HOME="$TEST_HOME/.codex" "$CODEX_BIN" login status 2>&1 | grep -qi 'ChatGPT' \
    || fail "real Codex CLI did not preserve ChatGPT auth with a custom provider"
fi

HOME="$TEST_HOME" bash "$CCS" codex use openai >/dev/null
assert_eq "$(jq -r '.tokens.refresh_token' "$TEST_HOME/.codex/auth.json")" "refresh"
assert_eq "$(HOME="$TEST_HOME" bash "$CCS" codex current)" "openai"

printf '\n[model_providers.proxy.extra]\nnote = "keep-me"\n' >> "$TEST_HOME/.codex/config.toml"
printf 'proxy-key-2\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" \
    CCS_TEST_DISPLAY_NAME="Edited Proxy" \
    CCS_TEST_BASE_URL="https://proxy.example/v2" \
    CCS_TEST_RETRY_COUNT=9 \
    bash "$CCS" codex edit proxy >/dev/null
assert_contains "$TEST_HOME/.codex/config.toml" 'base_url = "https://proxy.example/v2"'
assert_contains "$TEST_HOME/.codex/config.toml" 'request_max_retries = 9'
assert_contains "$TEST_HOME/.codex/config.toml" '[model_providers.proxy.extra]'
assert_contains "$TEST_HOME/.codex/config.toml" 'note = "keep-me"'
assert_contains "$TEST_HOME/.codex/config.toml" 'requires_openai_auth = false'
assert_eq "$(grep -cF '[model_providers.proxy.auth]' "$TEST_HOME/.codex/config.toml")" "1"
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "proxy-key-2"
printf '\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" \
    CCS_TEST_DISPLAY_NAME="Edited Proxy" \
    CCS_TEST_BASE_URL="https://proxy.example/v3" \
    CCS_TEST_RETRY_COUNT=10 \
    bash "$CCS" codex edit proxy >/dev/null
assert_contains "$TEST_HOME/.codex/config.toml" 'base_url = "https://proxy.example/v3"'
assert_contains "$TEST_HOME/.codex/config.toml" 'request_max_retries = 10'
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "proxy-key-2"
show_output="$(HOME="$TEST_HOME" bash "$CCS" codex show proxy)"
[[ "$show_output" == *'api_key:  ***'* ]] || fail "show did not mask API key"
[[ "$show_output" != *'proxy-key-2'* ]] || fail "show leaked API key"

# Editor, fragment, key, auth, and concurrency failures leave no partial CCS writes.
stable_config_hash="$(shasum -a 256 "$TEST_HOME/.codex/config.toml" | cut -d' ' -f1)"
stable_provider_key="$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")"
if HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" CCS_TEST_EDITOR_MODE=fail \
  bash "$CCS" codex new editorfail >/dev/null 2>&1; then
  fail "provider creation succeeded after editor failure"
fi
if printf 'unused-key\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" CCS_TEST_WIRE_API=invalid \
    bash "$CCS" codex new invalid >/dev/null 2>&1; then
  fail "provider creation succeeded with an invalid fragment"
fi
if printf '\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" \
    CCS_TEST_BASE_URL="https://blank.example/v1" \
    bash "$CCS" codex new blankkey >/dev/null 2>&1; then
  fail "provider creation succeeded with a blank API key"
fi
assert_eq "$(shasum -a 256 "$TEST_HOME/.codex/config.toml" | cut -d' ' -f1)" "$stable_config_hash"
[[ ! -e "$TEST_HOME/.codex/ccs-auth/editorfail.json" ]] || fail "editor failure left an auth snapshot"
[[ ! -e "$TEST_HOME/.codex/ccs-auth/invalid.json" ]] || fail "invalid fragment left an auth snapshot"
[[ ! -e "$TEST_HOME/.codex/ccs-auth/blankkey.json" ]] || fail "blank key left an auth snapshot"

for invalid_mode in rename auth-table; do
  if printf 'unused-key\n' \
    | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" CCS_TEST_EDITOR_MODE="$invalid_mode" \
      bash "$CCS" codex edit proxy >/dev/null 2>&1; then
    fail "provider edit succeeded with invalid mode: $invalid_mode"
  fi
done
if printf 'unused-key\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" CCS_TEST_REQUIRES_OPENAI_AUTH=true \
    bash "$CCS" codex edit proxy >/dev/null 2>&1; then
  fail "provider edit accepted requires_openai_auth = true"
fi
assert_eq "$(shasum -a 256 "$TEST_HOME/.codex/config.toml" | cut -d' ' -f1)" "$stable_config_hash"
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "$stable_provider_key"

mv "$TEST_HOME/.codex/ccs-auth/proxy.json" "$TEST_HOME/.codex/ccs-auth/proxy.saved"
if printf '\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" \
    CCS_TEST_BASE_URL="https://missing-auth.example/v1" \
    bash "$CCS" codex edit proxy >/dev/null 2>&1; then
  fail "provider edit kept a missing auth snapshot"
fi
mv "$TEST_HOME/.codex/ccs-auth/proxy.saved" "$TEST_HOME/.codex/ccs-auth/proxy.json"
assert_eq "$(shasum -a 256 "$TEST_HOME/.codex/config.toml" | cut -d' ' -f1)" "$stable_config_hash"

if printf 'race-key\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" CCS_TEST_EDITOR_MODE=concurrent \
    CCS_TEST_BASE_URL="https://editor-race.example/v1" \
    CCS_TEST_CONCURRENT_URL="https://concurrent.example/v1" \
    bash "$CCS" codex edit proxy >/dev/null 2>&1; then
  fail "provider edit overwrote a concurrent provider change"
fi
assert_contains "$TEST_HOME/.codex/config.toml" 'base_url = "https://concurrent.example/v1"'
assert_not_contains "$TEST_HOME/.codex/config.toml" 'base_url = "https://editor-race.example/v1"'
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "$stable_provider_key"
assert_no_ccs_temps "$TEST_HOME"
assert_eq "$(shasum -a 256 "$TEST_HOME/.codex/auth.json" | cut -d' ' -f1)" "$chatgpt_auth_hash"

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
assert_not_contains "$TEST_HOME/.codex/config.toml" '[model_providers.proxy.auth]'
[[ ! -e "$TEST_HOME/.codex/ccs-auth/proxy.json" ]] || fail "proxy auth snapshot still exists"

# v0.2 migration: preserve ChatGPT, import API key, and retain the formerly active provider.
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
assert_eq "$(jq -r '.auth_mode' "$MIGRATE_HOME/.codex/auth.json")" "chatgpt"
assert_eq "$(jq -r '.tokens.refresh_token' "$MIGRATE_HOME/.codex/auth.json")" "chatgpt-refresh"
assert_eq "$(jq -r '.tokens.refresh_token' "$MIGRATE_HOME/.codex/ccs-auth/openai.json")" "chatgpt-refresh"
assert_not_contains "$MIGRATE_HOME/.codex/config.toml" 'env_key ='
assert_contains "$MIGRATE_HOME/.codex/config.toml" 'requires_openai_auth = false'
assert_contains "$MIGRATE_HOME/.codex/config.toml" '[model_providers.of.auth]'
assert_contains "$MIGRATE_HOME/.codex/config.toml" "command = \"$JQ_BIN\""
assert_contains "$MIGRATE_HOME/.codex/config.toml" \
  "args = [\"-er\", \".OPENAI_API_KEY | strings | select(length > 0)\", \"$MIGRATE_HOME/.codex/ccs-auth/of.json\"]"
assert_eq "$("$JQ_BIN" -er '.OPENAI_API_KEY | strings | select(length > 0)' "$MIGRATE_HOME/.codex/ccs-auth/of.json")" "legacy-key"
assert_contains "$MIGRATE_HOME/.codex/config.toml" 'request_max_retries = 7'
assert_file "$MIGRATE_HOME/.codex/ccs-auth/.migrated-v2"
compgen -G "$MIGRATE_HOME/.config/ccs/codex/profiles.migrated-*" >/dev/null \
  || fail "legacy profiles backup missing"
assert_eq "$(HOME="$MIGRATE_HOME" bash "$CCS" codex current 2>/dev/null)" "of"

# v0.3 migration: convert auth snapshots to command auth and restore ChatGPT globally.
V3_HOME="$(mktemp -d)"
mkdir -p "$V3_HOME/.codex/ccs-auth"
printf '%s\n' \
  'model_provider = "proxy"' \
  '' \
  '[model_providers.proxy]' \
  'name = "proxy"' \
  'base_url = "https://proxy.example/v1"' \
  'wire_api = "responses"' \
  'requires_openai_auth = true' > "$V3_HOME/.codex/config.toml"
jq -n --arg key 'proxy-key' '{auth_mode:"apikey",OPENAI_API_KEY:$key}' \
  > "$V3_HOME/.codex/auth.json"
jq -n '{auth_mode:"chatgpt",OPENAI_API_KEY:null,tokens:{refresh_token:"v3-refresh"}}' \
  > "$V3_HOME/.codex/ccs-auth/openai.json"
jq -n --arg key 'proxy-key' '{auth_mode:"apikey",OPENAI_API_KEY:$key}' \
  > "$V3_HOME/.codex/ccs-auth/proxy.json"
: > "$V3_HOME/.codex/ccs-auth/.migrated-v1"
chmod 600 "$V3_HOME/.codex/auth.json" "$V3_HOME/.codex/ccs-auth/"*.json

assert_eq "$(HOME="$V3_HOME" bash "$CCS" codex current)" "proxy"
assert_contains "$V3_HOME/.codex/config.toml" 'requires_openai_auth = false'
assert_contains "$V3_HOME/.codex/config.toml" '[model_providers.proxy.auth]'
assert_eq "$(jq -r '.auth_mode' "$V3_HOME/.codex/auth.json")" "chatgpt"
assert_eq "$(jq -r '.tokens.refresh_token' "$V3_HOME/.codex/auth.json")" "v3-refresh"
assert_contains "$V3_HOME/.codex/config.toml" "command = \"$JQ_BIN\""
assert_contains "$V3_HOME/.codex/config.toml" \
  "args = [\"-er\", \".OPENAI_API_KEY | strings | select(length > 0)\", \"$V3_HOME/.codex/ccs-auth/proxy.json\"]"
assert_eq "$("$JQ_BIN" -er '.OPENAI_API_KEY | strings | select(length > 0)' "$V3_HOME/.codex/ccs-auth/proxy.json")" "proxy-key"
assert_file "$V3_HOME/.codex/ccs-auth/.migrated-v2"

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
printf 'new-user-proxy-key\n' \
  | HOME="$NEW_USER_HOME" PATH="$FAKE_BIN:$PATH" EDITOR="$EDITOR_CMD" \
    CCS_TEST_DISPLAY_NAME="New User Proxy" \
    CCS_TEST_BASE_URL="https://new-user-proxy.example/v1" \
    bash "$CCS" codex new proxy >/dev/null
HOME="$NEW_USER_HOME" PATH="$FAKE_BIN:$PATH" bash "$CCS" codex use proxy >/dev/null
HOME="$NEW_USER_HOME" PATH="$FAKE_BIN:$PATH" bash "$CCS" codex login >/dev/null
assert_eq "$(jq -r '.tokens.account_id' "$NEW_USER_HOME/.codex/ccs-auth/openai.json")" "native-account"
assert_eq "$(jq -r '.OPENAI_API_KEY' "$NEW_USER_HOME/.codex/ccs-auth/proxy.json")" "new-user-proxy-key"
assert_eq "$(HOME="$NEW_USER_HOME" bash "$CCS" codex current)" "openai"

# Initialization must not wrap Codex or restore Codex environment profiles.
assert_not_contains "$ROOT/init.sh" 'codex()'
assert_not_contains "$ROOT/init.sh" 'CCS_CODEX'
assert_not_contains "$ROOT/init.fish" 'function codex'
assert_not_contains "$ROOT/init.fish" 'CCS_CODEX'

echo "PASS: Codex file-mode integration"
