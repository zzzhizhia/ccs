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
config_without_provider_hash() {
  awk '
    {
      header=$0
      sub(/[[:space:]]*#.*/, "", header)
      gsub(/[[:space:]]/, "", header)
    }
    header ~ /^\[model_providers\.[A-Za-z_][A-Za-z0-9_-]*(\..*)?\]$/ { skip=1; next }
    skip && header ~ /^\[/ { skip=0 }
    !skip { print }
  ' "$1" | shasum -a 256 | cut -d' ' -f1
}
assert_fixed_provider_state() {
  local home="$1" logical="$2" non_provider_hash="$3" auth_hash="$4"
  local config="$home/.codex/config.toml" current list_output show_output
  assert_eq "$(grep -cE '^model_provider[[:space:]]*=' "$config")" "1"
  assert_eq "$(sed -nE 's/^model_provider[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' "$config")" "ccs"
  assert_eq "$(grep -cE '^\[model_providers\.[A-Za-z_][A-Za-z0-9_-]*\]$' "$config")" "1"
  assert_eq "$(grep -cF '[model_providers.ccs]' "$config")" "1"
  assert_not_contains "$config" '[model_providers.proxy]'
  assert_not_contains "$config" '[model_providers.openai]'
  assert_eq "$(config_without_provider_hash "$config")" "$non_provider_hash"
  assert_eq "$(shasum -a 256 "$home/.codex/auth.json" | cut -d' ' -f1)" "$auth_hash"
  current="$(HOME="$home" bash "$CCS" codex current)"
  assert_eq "$current" "$logical"
  list_output="$(HOME="$home" bash "$CCS" codex list)"
  grep -Eq "^[[:space:]]+${logical}[[:space:]]+\* active" <<< "$list_output" \
    || fail "list did not mark logical provider '$logical' active"
  show_output="$(HOME="$home" bash "$CCS" codex show)"
  [[ "$show_output" == "provider: $logical"$'\n'* ]] \
    || fail "show did not report logical provider '$logical'"
}
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
assert_eq "$(bash "$CCS" version)" "ccs 0.6.0"
assert_file "$TEST_HOME/.codex/ccs-auth/openai.json"
assert_eq "$(jq -r '.tokens.refresh_token' "$TEST_HOME/.codex/ccs-auth/openai.json")" "refresh"
assert_file "$TEST_HOME/.codex/ccs-auth/.migrated-v2"

printf 'proxy-key\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" \
    CCS_TEST_DISPLAY_NAME="Proxy via editor" \
    CCS_TEST_BASE_URL="https://proxy.example/v1" \
    CCS_TEST_RETRY_COUNT=7 \
    bash "$CCS" codex new proxy >/dev/null
proxy_profile="$TEST_HOME/.codex/ccs-providers/proxy.toml"
assert_file "$proxy_profile"
assert_contains "$proxy_profile" '[model_providers.proxy]'
assert_contains "$proxy_profile" 'name = "Proxy via editor"'
assert_contains "$proxy_profile" 'request_max_retries = 7'
assert_contains "$proxy_profile" 'requires_openai_auth = false'
assert_not_contains "$proxy_profile" 'env_key ='
assert_not_contains "$TEST_HOME/.codex/config.toml" 'proxy-key'
assert_not_contains "$proxy_profile" '[model_providers.proxy.auth]'
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "proxy-key"
assert_eq "$("$JQ_BIN" -er '.OPENAI_API_KEY | strings | select(length > 0)' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "proxy-key"
assert_eq "$(jq -r '.tokens.refresh_token' "$TEST_HOME/.codex/auth.json")" "refresh"
assert_eq "$(stat -f '%Lp' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "600"
assert_eq "$(stat -f '%Lp' "$TEST_HOME/.codex/ccs-auth")" "700"

non_provider_hash="$(config_without_provider_hash "$TEST_HOME/.codex/config.toml")"
for logical in proxy openai proxy; do
  HOME="$TEST_HOME" bash "$CCS" codex use "$logical" >/dev/null
  assert_fixed_provider_state "$TEST_HOME" "$logical" "$non_provider_hash" "$chatgpt_auth_hash"
done
assert_contains "$TEST_HOME/.codex/config.toml" '[model_providers.ccs.auth]'
assert_contains "$TEST_HOME/.codex/config.toml" "command = \"$JQ_BIN\""
assert_contains "$TEST_HOME/.codex/config.toml" \
  "args = [\"-er\", \".OPENAI_API_KEY | strings | select(length > 0)\", \"$TEST_HOME/.codex/ccs-auth/proxy.json\"]"

HOME="$TEST_HOME" bash "$CCS" codex use proxy >/dev/null
assert_contains "$TEST_HOME/.codex/config.toml" 'model_provider = "ccs"'
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
assert_not_contains "$TEST_HOME/.codex/config.toml" '[model_providers.ccs.auth]'

printf '\n[model_providers.proxy.extra]\nnote = "keep-me"\n' >> "$proxy_profile"
printf 'proxy-key-2\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" \
    CCS_TEST_DISPLAY_NAME="Edited Proxy" \
    CCS_TEST_BASE_URL="https://proxy.example/v2" \
    CCS_TEST_RETRY_COUNT=9 \
    bash "$CCS" codex edit proxy >/dev/null
assert_contains "$proxy_profile" 'base_url = "https://proxy.example/v2"'
assert_contains "$proxy_profile" 'request_max_retries = 9'
assert_contains "$proxy_profile" '[model_providers.proxy.extra]'
assert_contains "$proxy_profile" 'note = "keep-me"'
assert_contains "$proxy_profile" 'requires_openai_auth = false'
assert_eq "$(grep -cF '[model_providers.proxy.auth]' "$proxy_profile")" "0"
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "proxy-key-2"
printf '\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" \
    CCS_TEST_DISPLAY_NAME="Edited Proxy" \
    CCS_TEST_BASE_URL="https://proxy.example/v3" \
    CCS_TEST_RETRY_COUNT=10 \
    bash "$CCS" codex edit proxy >/dev/null
assert_contains "$proxy_profile" 'base_url = "https://proxy.example/v3"'
assert_contains "$proxy_profile" 'request_max_retries = 10'
assert_eq "$(jq -r '.OPENAI_API_KEY' "$TEST_HOME/.codex/ccs-auth/proxy.json")" "proxy-key-2"
show_output="$(HOME="$TEST_HOME" bash "$CCS" codex show proxy)"
[[ "$show_output" == *'api_key:  ***'* ]] || fail "show did not mask API key"
[[ "$show_output" != *'proxy-key-2'* ]] || fail "show leaked API key"

# Editing the active logical profile immediately refreshes the fixed provider table.
HOME="$TEST_HOME" bash "$CCS" codex use proxy >/dev/null
printf '\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" \
    CCS_TEST_DISPLAY_NAME="Edited Proxy" \
    CCS_TEST_BASE_URL="https://proxy.example/v4" \
    CCS_TEST_RETRY_COUNT=11 \
    bash "$CCS" codex edit proxy >/dev/null
assert_contains "$proxy_profile" 'base_url = "https://proxy.example/v4"'
assert_contains "$TEST_HOME/.codex/config.toml" 'base_url = "https://proxy.example/v4"'
assert_contains "$TEST_HOME/.codex/config.toml" '[model_providers.ccs.extra]'
assert_contains "$TEST_HOME/.codex/config.toml" 'note = "keep-me"'

# Editor, fragment, key, auth, and concurrency failures leave no partial CCS writes.
stable_config_hash="$(shasum -a 256 "$TEST_HOME/.codex/config.toml" | cut -d' ' -f1)"
stable_profile_hash="$(shasum -a 256 "$proxy_profile" | cut -d' ' -f1)"
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
assert_eq "$(shasum -a 256 "$proxy_profile" | cut -d' ' -f1)" "$stable_profile_hash"
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
assert_eq "$(shasum -a 256 "$proxy_profile" | cut -d' ' -f1)" "$stable_profile_hash"
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
assert_eq "$(shasum -a 256 "$proxy_profile" | cut -d' ' -f1)" "$stable_profile_hash"

if printf 'race-key\n' \
  | HOME="$TEST_HOME" EDITOR="$EDITOR_CMD" CCS_TEST_EDITOR_MODE=concurrent \
    CCS_TEST_BASE_URL="https://editor-race.example/v1" \
    CCS_TEST_CONCURRENT_URL="https://concurrent.example/v1" \
    bash "$CCS" codex edit proxy >/dev/null 2>&1; then
  fail "provider edit overwrote a concurrent provider change"
fi
assert_contains "$proxy_profile" 'base_url = "https://concurrent.example/v1"'
assert_not_contains "$proxy_profile" 'base_url = "https://editor-race.example/v1"'
assert_contains "$TEST_HOME/.codex/config.toml" 'base_url = "https://proxy.example/v4"'
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
USE_FAIL_BIN="$(mktemp -d)"
cp "$ROOT/tests/fixtures/mv-fail-current" "$USE_FAIL_BIN/mv"
chmod +x "$USE_FAIL_BIN/mv"
if HOME="$TEST_HOME" PATH="$USE_FAIL_BIN:$PATH" bash "$CCS" codex use openai >/dev/null 2>&1; then
  fail "switch succeeded after the current-link commit failed"
fi
assert_eq "$(shasum -a 256 "$TEST_HOME/.codex/config.toml" | cut -d' ' -f1)" "$config_hash"
assert_eq "$(HOME="$TEST_HOME" bash "$CCS" codex current)" "proxy"
assert_eq "$(shasum -a 256 "$TEST_HOME/.codex/auth.json" | cut -d' ' -f1)" "$auth_hash"
assert_no_ccs_temps "$TEST_HOME"
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
[[ ! -e "$proxy_profile" ]] || fail "proxy logical profile still exists"
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
assert_contains "$MIGRATE_HOME/.codex/config.toml" 'model_provider = "ccs"'
assert_contains "$MIGRATE_HOME/.codex/config.toml" '[model_providers.ccs]'
assert_contains "$MIGRATE_HOME/.codex/config.toml" '[model_providers.ccs.auth]'
assert_not_contains "$MIGRATE_HOME/.codex/config.toml" '[model_providers.of]'
assert_contains "$MIGRATE_HOME/.codex/config.toml" "command = \"$JQ_BIN\""
assert_contains "$MIGRATE_HOME/.codex/config.toml" \
  "args = [\"-er\", \".OPENAI_API_KEY | strings | select(length > 0)\", \"$MIGRATE_HOME/.codex/ccs-auth/of.json\"]"
assert_eq "$("$JQ_BIN" -er '.OPENAI_API_KEY | strings | select(length > 0)' "$MIGRATE_HOME/.codex/ccs-auth/of.json")" "legacy-key"
assert_contains "$MIGRATE_HOME/.codex/config.toml" 'request_max_retries = 7'
assert_file "$MIGRATE_HOME/.codex/ccs-auth/.migrated-v2"
assert_file "$MIGRATE_HOME/.codex/ccs-providers/.migrated-v3"
assert_contains "$MIGRATE_HOME/.codex/ccs-providers/of.toml" '[model_providers.of]'
assert_contains "$MIGRATE_HOME/.codex/ccs-providers/of.toml" 'request_max_retries = 7'
assert_eq "$(basename "$(readlink "$MIGRATE_HOME/.codex/ccs-providers/current")" .toml)" "of"
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
assert_contains "$V3_HOME/.codex/config.toml" 'model_provider = "ccs"'
assert_contains "$V3_HOME/.codex/config.toml" '[model_providers.ccs.auth]'
assert_not_contains "$V3_HOME/.codex/config.toml" '[model_providers.proxy]'
assert_eq "$(jq -r '.auth_mode' "$V3_HOME/.codex/auth.json")" "chatgpt"
assert_eq "$(jq -r '.tokens.refresh_token' "$V3_HOME/.codex/auth.json")" "v3-refresh"
assert_contains "$V3_HOME/.codex/config.toml" "command = \"$JQ_BIN\""
assert_contains "$V3_HOME/.codex/config.toml" \
  "args = [\"-er\", \".OPENAI_API_KEY | strings | select(length > 0)\", \"$V3_HOME/.codex/ccs-auth/proxy.json\"]"
assert_eq "$("$JQ_BIN" -er '.OPENAI_API_KEY | strings | select(length > 0)' "$V3_HOME/.codex/ccs-auth/proxy.json")" "proxy-key"
assert_file "$V3_HOME/.codex/ccs-auth/.migrated-v2"
assert_file "$V3_HOME/.codex/ccs-providers/.migrated-v3"
assert_contains "$V3_HOME/.codex/ccs-providers/proxy.toml" '[model_providers.proxy]'

# Fixed-provider migration: built-in OpenAI keeps ChatGPT OAuth and gains the constant table.
BUILTIN_HOME="$(mktemp -d)"
mkdir -p "$BUILTIN_HOME/.codex/ccs-auth"
printf '%s\n' \
  'model_provider = "openai"' \
  'model = "gpt-built-in"' \
  '' \
  '[features]' \
  'unified_exec = true' > "$BUILTIN_HOME/.codex/config.toml"
jq -n '{auth_mode:"chatgpt",tokens:{refresh_token:"built-in-refresh"}}' \
  > "$BUILTIN_HOME/.codex/auth.json"
cp "$BUILTIN_HOME/.codex/auth.json" "$BUILTIN_HOME/.codex/ccs-auth/openai.json"
: > "$BUILTIN_HOME/.codex/ccs-auth/.migrated-v2"
chmod 600 "$BUILTIN_HOME/.codex/auth.json" "$BUILTIN_HOME/.codex/ccs-auth/"*
built_in_auth_hash="$(shasum -a 256 "$BUILTIN_HOME/.codex/auth.json" | cut -d' ' -f1)"
assert_eq "$(HOME="$BUILTIN_HOME" bash "$CCS" codex current 2>/dev/null)" "openai"
assert_contains "$BUILTIN_HOME/.codex/config.toml" 'model_provider = "ccs"'
assert_contains "$BUILTIN_HOME/.codex/config.toml" '[model_providers.ccs]'
assert_contains "$BUILTIN_HOME/.codex/config.toml" 'base_url = "https://chatgpt.com/backend-api/codex"'
assert_contains "$BUILTIN_HOME/.codex/config.toml" 'requires_openai_auth = true'
assert_not_contains "$BUILTIN_HOME/.codex/config.toml" '[model_providers.ccs.auth]'
assert_contains "$BUILTIN_HOME/.codex/config.toml" 'unified_exec = true'
assert_eq "$(shasum -a 256 "$BUILTIN_HOME/.codex/auth.json" | cut -d' ' -f1)" "$built_in_auth_hash"
built_in_backup="$(find "$BUILTIN_HOME/.codex/ccs-backups" -type f -name config.toml -print -quit)"
assert_file "$built_in_backup"
assert_eq "$(stat -f '%Lp' "$built_in_backup")" "600"

# Multiple legacy providers and nested tables become logical profiles; only the active one is materialized.
NESTED_HOME="$(mktemp -d)"
mkdir -p "$NESTED_HOME/.codex/ccs-auth"
printf '%s\n' \
  'model_provider = "proxy"' \
  'model = "gpt-nested"' \
  '' \
  '[features]' \
  'unified_exec = true' \
  '' \
  '[model_providers.proxy]' \
  'name = "Proxy"' \
  'base_url = "https://proxy.example/v1"' \
  'wire_api = "responses"' \
  'requires_openai_auth = false' \
  '' \
  '[model_providers.proxy.extra]' \
  'note = "proxy-extra"' \
  '' \
  '[model_providers.proxy.auth]' \
  'command = "legacy-command"' \
  '' \
  '[model_providers.other]' \
  'name = "Other"' \
  'base_url = "https://other.example/v1"' \
  'wire_api = "chat"' \
  'requires_openai_auth = false' \
  '' \
  '[model_providers.other.tuning]' \
  'request_max_retries = 4' \
  '' \
  '[model_providers.other.auth]' \
  'command = "legacy-command"' > "$NESTED_HOME/.codex/config.toml"
jq -n '{auth_mode:"chatgpt",tokens:{refresh_token:"nested-refresh"}}' > "$NESTED_HOME/.codex/auth.json"
cp "$NESTED_HOME/.codex/auth.json" "$NESTED_HOME/.codex/ccs-auth/openai.json"
jq -n --arg key 'nested-proxy-key' '{auth_mode:"apikey",OPENAI_API_KEY:$key}' \
  > "$NESTED_HOME/.codex/ccs-auth/proxy.json"
jq -n --arg key 'nested-other-key' '{auth_mode:"apikey",OPENAI_API_KEY:$key}' \
  > "$NESTED_HOME/.codex/ccs-auth/other.json"
: > "$NESTED_HOME/.codex/ccs-auth/.migrated-v2"
chmod 600 "$NESTED_HOME/.codex/auth.json" "$NESTED_HOME/.codex/ccs-auth/"*
nested_auth_hash="$(shasum -a 256 "$NESTED_HOME/.codex/auth.json" | cut -d' ' -f1)"
nested_proxy_hash="$(shasum -a 256 "$NESTED_HOME/.codex/ccs-auth/proxy.json" | cut -d' ' -f1)"
nested_other_hash="$(shasum -a 256 "$NESTED_HOME/.codex/ccs-auth/other.json" | cut -d' ' -f1)"
assert_eq "$(HOME="$NESTED_HOME" bash "$CCS" codex current 2>/dev/null)" "proxy"
assert_eq "$(grep -cE '^\[model_providers\.[A-Za-z_][A-Za-z0-9_-]*\]$' "$NESTED_HOME/.codex/config.toml")" "1"
assert_contains "$NESTED_HOME/.codex/config.toml" '[model_providers.ccs.extra]'
assert_not_contains "$NESTED_HOME/.codex/config.toml" '[model_providers.proxy]'
assert_not_contains "$NESTED_HOME/.codex/config.toml" '[model_providers.other]'
assert_contains "$NESTED_HOME/.codex/ccs-providers/proxy.toml" '[model_providers.proxy.extra]'
assert_contains "$NESTED_HOME/.codex/ccs-providers/other.toml" '[model_providers.other.tuning]'
assert_not_contains "$NESTED_HOME/.codex/ccs-providers/proxy.toml" '[model_providers.proxy.auth]'
assert_not_contains "$NESTED_HOME/.codex/ccs-providers/other.toml" '[model_providers.other.auth]'
assert_eq "$(shasum -a 256 "$NESTED_HOME/.codex/auth.json" | cut -d' ' -f1)" "$nested_auth_hash"
assert_eq "$(shasum -a 256 "$NESTED_HOME/.codex/ccs-auth/proxy.json" | cut -d' ' -f1)" "$nested_proxy_hash"
assert_eq "$(shasum -a 256 "$NESTED_HOME/.codex/ccs-auth/other.json" | cut -d' ' -f1)" "$nested_other_hash"

# Migration conflicts and malformed/missing inputs fail before any partial fixed-provider state appears.
for failure_mode in fixed-conflict bad-toml missing-auth; do
  FAILURE_HOME="$(mktemp -d)"
  mkdir -p "$FAILURE_HOME/.codex/ccs-auth"
  case "$failure_mode" in
    fixed-conflict)
      printf '%s\n' \
        'model_provider = "proxy"' \
        '[model_providers.proxy]' \
        'name = "Proxy"' \
        'base_url = "https://proxy.example/v1"' \
        'wire_api = "responses"' \
        'requires_openai_auth = false' \
        '[model_providers.ccs]' \
        'name = "Collision"' \
        'base_url = "https://collision.example/v1"' \
        'wire_api = "responses"' \
        'requires_openai_auth = false' > "$FAILURE_HOME/.codex/config.toml"
      ;;
    bad-toml)
      printf '%s\n' 'model_provider = "proxy"' '[model_providers.proxy' \
        'base_url = "https://proxy.example/v1"' > "$FAILURE_HOME/.codex/config.toml"
      ;;
    missing-auth)
      printf '%s\n' \
        'model_provider = "proxy"' \
        '[model_providers.proxy]' \
        'name = "Proxy"' \
        'base_url = "https://proxy.example/v1"' \
        'wire_api = "responses"' \
        'requires_openai_auth = false' > "$FAILURE_HOME/.codex/config.toml"
      ;;
  esac
  jq -n '{auth_mode:"chatgpt",tokens:{refresh_token:"failure-refresh"}}' > "$FAILURE_HOME/.codex/auth.json"
  cp "$FAILURE_HOME/.codex/auth.json" "$FAILURE_HOME/.codex/ccs-auth/openai.json"
  if [[ "$failure_mode" != "missing-auth" ]]; then
    jq -n --arg key 'failure-proxy-key' '{auth_mode:"apikey",OPENAI_API_KEY:$key}' \
      > "$FAILURE_HOME/.codex/ccs-auth/proxy.json"
  fi
  : > "$FAILURE_HOME/.codex/ccs-auth/.migrated-v2"
  chmod 600 "$FAILURE_HOME/.codex/auth.json" "$FAILURE_HOME/.codex/ccs-auth/"*
  failure_config_hash="$(shasum -a 256 "$FAILURE_HOME/.codex/config.toml" | cut -d' ' -f1)"
  failure_auth_hash="$(shasum -a 256 "$FAILURE_HOME/.codex/auth.json" | cut -d' ' -f1)"
  if HOME="$FAILURE_HOME" bash "$CCS" codex list >/dev/null 2>&1; then
    fail "$failure_mode migration unexpectedly succeeded"
  fi
  assert_eq "$(shasum -a 256 "$FAILURE_HOME/.codex/config.toml" | cut -d' ' -f1)" "$failure_config_hash"
  assert_eq "$(shasum -a 256 "$FAILURE_HOME/.codex/auth.json" | cut -d' ' -f1)" "$failure_auth_hash"
  [[ ! -e "$FAILURE_HOME/.codex/ccs-providers" ]] || fail "$failure_mode migration left a provider directory"
  assert_no_ccs_temps "$FAILURE_HOME"
done

# Lock contention and TERM during the two-file commit leave config/current/auth unchanged.
LOCK_HOME="$(mktemp -d)"
mkdir -p "$LOCK_HOME/.codex/ccs-auth" "$LOCK_HOME/.codex/.ccs.lock"
printf '%s\n' 'model_provider = "openai"' 'model = "locked"' > "$LOCK_HOME/.codex/config.toml"
jq -n '{auth_mode:"chatgpt",tokens:{refresh_token:"locked-refresh"}}' > "$LOCK_HOME/.codex/auth.json"
cp "$LOCK_HOME/.codex/auth.json" "$LOCK_HOME/.codex/ccs-auth/openai.json"
: > "$LOCK_HOME/.codex/ccs-auth/.migrated-v2"
lock_config_hash="$(shasum -a 256 "$LOCK_HOME/.codex/config.toml" | cut -d' ' -f1)"
if HOME="$LOCK_HOME" bash "$CCS" codex current >/dev/null 2>&1; then
  fail "fixed-provider migration succeeded while lock was held"
fi
assert_eq "$(shasum -a 256 "$LOCK_HOME/.codex/config.toml" | cut -d' ' -f1)" "$lock_config_hash"
[[ ! -e "$LOCK_HOME/.codex/ccs-providers" ]] || fail "lock failure left a provider directory"

INTERRUPT_HOME="$(mktemp -d)"
INTERRUPT_BIN="$(mktemp -d)"
mkdir -p "$INTERRUPT_HOME/.codex/ccs-auth"
printf '%s\n' \
  'model_provider = "proxy"' \
  'model = "interrupted"' \
  '[model_providers.proxy]' \
  'name = "Proxy"' \
  'base_url = "https://proxy.example/v1"' \
  'wire_api = "responses"' \
  'requires_openai_auth = false' > "$INTERRUPT_HOME/.codex/config.toml"
jq -n '{auth_mode:"chatgpt",tokens:{refresh_token:"interrupt-refresh"}}' > "$INTERRUPT_HOME/.codex/auth.json"
cp "$INTERRUPT_HOME/.codex/auth.json" "$INTERRUPT_HOME/.codex/ccs-auth/openai.json"
jq -n --arg key 'interrupt-proxy-key' '{auth_mode:"apikey",OPENAI_API_KEY:$key}' \
  > "$INTERRUPT_HOME/.codex/ccs-auth/proxy.json"
: > "$INTERRUPT_HOME/.codex/ccs-auth/.migrated-v2"
cp "$ROOT/tests/fixtures/mv-interrupt" "$INTERRUPT_BIN/mv"
chmod +x "$INTERRUPT_BIN/mv"
interrupt_config_hash="$(shasum -a 256 "$INTERRUPT_HOME/.codex/config.toml" | cut -d' ' -f1)"
interrupt_auth_hash="$(shasum -a 256 "$INTERRUPT_HOME/.codex/auth.json" | cut -d' ' -f1)"
if HOME="$INTERRUPT_HOME" PATH="$INTERRUPT_BIN:$PATH" bash "$CCS" codex list >/dev/null 2>&1; then
  fail "interrupted fixed-provider migration unexpectedly succeeded"
fi
assert_eq "$(shasum -a 256 "$INTERRUPT_HOME/.codex/config.toml" | cut -d' ' -f1)" "$interrupt_config_hash"
assert_eq "$(shasum -a 256 "$INTERRUPT_HOME/.codex/auth.json" | cut -d' ' -f1)" "$interrupt_auth_hash"
[[ ! -e "$INTERRUPT_HOME/.codex/ccs-providers" ]] || fail "interrupted migration left a provider directory"
assert_no_ccs_temps "$INTERRUPT_HOME"

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
assert_eq "$(grep -cF 'model_provider = "ccs"' "$NEW_USER_HOME/.codex/config.toml")" "1"
assert_eq "$(grep -cF '[model_providers.ccs]' "$NEW_USER_HOME/.codex/config.toml")" "1"
assert_not_contains "$NEW_USER_HOME/.codex/config.toml" '[model_providers.openai]'
assert_not_contains "$NEW_USER_HOME/.codex/config.toml" '[model_providers.proxy]'

# Initialization must not wrap Codex or restore Codex environment profiles.
assert_not_contains "$ROOT/init.sh" 'codex()'
assert_not_contains "$ROOT/init.sh" 'CCS_CODEX'
assert_not_contains "$ROOT/init.fish" 'function codex'
assert_not_contains "$ROOT/init.fish" 'CCS_CODEX'

echo "PASS: Codex file-mode integration"
