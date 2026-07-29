#!/bin/bash
# ccs — Claude Code Switch
# https://github.com/zzzhizhia/ccs
# Standalone script. The thin shell wrapper evals stdout only for Claude
# use/env/source/unset so those commands affect the calling shell. Codex
# provider commands update ~/.codex files directly and never need eval.

set -euo pipefail

VERSION="0.4.0"
REPO="https://raw.githubusercontent.com/zzzhizhia/ccs/main"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CCS_DIR="${CCS_DIR:-$XDG_CONFIG_HOME/ccs/profiles}"
CCS_STATE="${CCS_STATE:-$XDG_STATE_HOME/ccs}"
CURRENT="$CCS_STATE/current"
CCS_CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CCS_STATUSLINE_SCRIPT="$XDG_CONFIG_HOME/ccs/statusline.sh"
CODEX_DIR="$HOME/.codex"
CODEX_CONFIG="$CODEX_DIR/config.toml"
CODEX_AUTH="$CODEX_DIR/auth.json"
CODEX_AUTH_DIR="$CODEX_DIR/ccs-auth"
CODEX_LOCK="$CODEX_DIR/.ccs.lock"
CODEX_MIGRATION_MARKER="$CODEX_AUTH_DIR/.migrated-v2"

mkdir -p "$CCS_DIR" "$CCS_STATE"

# Single source of truth for all Claude Code env vars managed by ccs.
CCS_VARS=(
  "ANTHROPIC_BASE_URL="
  "ANTHROPIC_AUTH_TOKEN="
  "ANTHROPIC_MODEL="
  "ANTHROPIC_DEFAULT_OPUS_MODEL="
  "ANTHROPIC_DEFAULT_SONNET_MODEL="
  "ANTHROPIC_DEFAULT_HAIKU_MODEL="
  "CLAUDE_CODE_SUBAGENT_MODEL="
  "CLAUDE_CODE_EFFORT_LEVEL="
  "CLAUDE_CODE_ATTRIBUTION_HEADER=0"
)

die() { echo "ccs: $*" >&2; exit 1; }

# Extract export variable names from a profile file.
_profile_vars() {
  local file="$1"
  while IFS= read -r line; do
    if [[ "$line" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done < "$file"
}

# ── statusline helpers ────────────────────────────────────────────────

# Write the fixed statusLine config into ~/.claude/settings.json.
# Idempotent — skips if already pointing to CCS_STATUSLINE_SCRIPT.
_ensure_statusline_setting() {
  local settings="$CCS_CLAUDE_SETTINGS"
  if [[ -f "$settings" ]]; then
    local existing
    existing=$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null) || true
    [[ "$existing" == "$CCS_STATUSLINE_SCRIPT" ]] && return 0
  fi
  if ! command -v jq &>/dev/null; then
    echo "ccs: jq is required for statusline. Install: brew install jq" >&2
    return 1
  fi
  local tmp="$settings.tmp.$$"
  if [[ -f "$settings" ]]; then
    jq --arg cmd "$CCS_STATUSLINE_SCRIPT" \
      '. + {"statusLine": {"type": "command", "command": $cmd}}' \
      "$settings" > "$tmp" && mv "$tmp" "$settings"
  else
    mkdir -p "$(dirname "$settings")"
    printf '{"statusLine": {"type": "command", "command": "%s"}}\n' "$CCS_STATUSLINE_SCRIPT" > "$settings"
  fi
}

# Apply a profile's .statusline to the runtime statusline script.
_apply_profile_statusline() {
  local name="$1"
  local src="$CCS_DIR/$name.statusline"
  local dst="$CCS_STATUSLINE_SCRIPT"

  [[ -f "$src" ]] || return 0

  _ensure_statusline_setting || return 1

  {
    printf '#!/bin/bash\n'
    printf '# ccs statusline for %s\n' "$name"
    printf '# Guard against empty HOME in non-login shells.\n'
    printf 'HOME="${HOME:-%s}"\n' "$HOME"
    cat "$src"
  } > "$dst"
  chmod +x "$dst"
}

# Clear the runtime statusline (called on unset) — only if ccs owns it.
_clear_statusline() {
  local dst="$CCS_STATUSLINE_SCRIPT"
  if [[ -f "$dst" ]] && grep -qF '# ccs statusline' "$dst" 2>/dev/null; then
    printf '#!/bin/bash\n# ccs statusline — no active profile\n' > "$dst"
    chmod +x "$dst"
  fi
}

# ── commands that output shell code (eval'd by wrapper) ──────────────

cmd_use() {
  local name="${1:-}"; [[ -z "$name" ]] && die "usage: ccs use <profile>"
  local profile="$CCS_DIR/$name.env"
  [[ -f "$profile" ]] || die "profile '$name' not found"

  # Unset vars from the previous profile first to avoid stale env
  if [[ -L "$CURRENT" ]]; then
    local old_profile
    old_profile="$(readlink "$CURRENT")"
    if [[ -f "$old_profile" ]]; then
      local old_vars
      old_vars="$(_profile_vars "$old_profile" | tr '\n' ' ')"
      [[ -n "${old_vars// }" ]] && echo "unset ${old_vars% }"
    else
      rm -f "$CURRENT"
    fi
  fi

  ln -sf "$profile" "$CURRENT"
  echo "source $CURRENT"
  echo "✓ ccs: switched to '$name'" >&2
  cmd_show "$name" >&2
  _apply_profile_statusline "$name"
}

cmd_source() {
  local name="${1:-}"; [[ -z "$name" ]] && die "usage: ccs env <profile>"
  local profile="$CCS_DIR/$name.env"
  [[ -f "$profile" ]] || die "profile '$name' not found"
  echo "source $profile"
  echo "✓ ccs: sourced '$name' (current terminal only)" >&2
  cmd_show "$name" >&2
  # For env: apply the profile's statusline if it has one; otherwise clear
  # the temporary statusline so it doesn't show a stale profile.
  if [[ -f "$CCS_DIR/$name.statusline" ]]; then
    _apply_profile_statusline "$name"
  else
    _clear_statusline
  fi
}

cmd_unset() {
  if [[ -L "$CURRENT" ]]; then
    local vars
    vars="$(_profile_vars "$(readlink "$CURRENT")" | tr '\n' ' ')"
    if [[ -n "${vars// }" ]]; then
      local name count
      name="$(basename "$(readlink "$CURRENT")" .env)"
      count="$(echo "$vars" | wc -w | tr -d ' ')"
      echo "unset ${vars% }"
      echo "✓ ccs: unset $count env vars from '$name'" >&2
    else
      echo "✓ ccs: no export vars found in profile" >&2
    fi
    rm -f "$CURRENT"
  else
    echo "✓ ccs: no active profile to unset" >&2
  fi
  _clear_statusline
}

# ── read-only / interactive commands (no eval needed) ─────────────────

cmd_list() {
  shopt -s nullglob
  local profiles=("$CCS_DIR"/*.env)
  if ((${#profiles[@]} == 0)); then
    echo "No profiles in $CCS_DIR — create one with: ccs new <name>"
    return
  fi
  local current="" target=""
  [[ -L "$CURRENT" ]] && target="$(readlink "$CURRENT")" && current="$(basename "$target" .env)"

  local max=0 name
  for p in "${profiles[@]}"; do
    name="$(basename "$p" .env)"
    ((${#name} > max)) && max=${#name}
  done

  for p in "${profiles[@]}"; do
    name="$(basename "$p" .env)"
    if [[ "$name" == "$current" ]]; then
      printf "  %-*s  * active\n" "$max" "$name"
    else
      printf "  %-*s\n" "$max" "$name"
    fi
  done
}

cmd_current() {
  if [[ -L "$CURRENT" ]]; then
    basename "$(readlink "$CURRENT")" .env
  fi
}

cmd_show() {
  local name="${1:-$(cmd_current)}"
  [[ -z "$name" ]] && die "No active profile (run: ccs show <name>)"
  local profile="$CCS_DIR/$name.env"
  [[ -f "$profile" ]] || die "profile '$name' not found"
  sed -E 's@(ANTHROPIC_(AUTH_TOKEN|API_KEY)=)[^[:space:]#]*@\1***@' "$profile"
}

cmd_new() {
  local name="${1:-}"; [[ -z "$name" ]] && die "usage: ccs new <profile>"
  local profile="$CCS_DIR/$name.env"
  [[ -e "$profile" ]] && die "profile '$name' already exists"
  {
    echo "# Claude Code env for: $name"
    echo "# Required: ANTHROPIC_AUTH_TOKEN (and usually ANTHROPIC_BASE_URL for non-1P)"
    for v in "${CCS_VARS[@]}"; do
      echo "export $v"
    done
  } > "$profile"
  echo "✓ ccs: created $profile"
  ${EDITOR:-vim} "$profile"
}

cmd_edit() {
  local name="${1:-}"; [[ -z "$name" ]] && die "usage: ccs edit <profile>"
  local profile="$CCS_DIR/$name.env"
  [[ -f "$profile" ]] || die "profile '$name' not found"
  ${EDITOR:-vim} "$profile"
}

cmd_rm() {
  local name="${1:-}"; [[ -z "$name" ]] && die "usage: ccs rm <profile>"
  local profile="$CCS_DIR/$name.env"
  [[ -f "$profile" ]] || die "no such profile '$name'"
  rm -i "$profile"
  [[ "$(cmd_current)" == "$name" ]] && rm -f "$CURRENT"
}

# ── Codex provider files ──────────────────────────────────────────────

_codex_require_jq() { command -v jq &>/dev/null || die "jq is required for ccs codex (install: brew install jq)"; }

_codex_init_dirs() {
  mkdir -p "$CODEX_DIR" "$CODEX_AUTH_DIR"
  chmod 700 "$CODEX_AUTH_DIR"
  [[ -f "$CODEX_CONFIG" ]] || : > "$CODEX_CONFIG"
}

_codex_lock_acquire() {
  _codex_init_dirs
  if ! mkdir "$CODEX_LOCK" 2>/dev/null; then
    die "another ccs codex operation is running (lock: $CODEX_LOCK)"
  fi
  trap '_codex_lock_release' EXIT HUP INT TERM
}

_codex_lock_release() {
  rmdir "$CODEX_LOCK" 2>/dev/null || true
  trap - EXIT HUP INT TERM
}

_codex_validate_auth() {
  local file="$1"
  [[ -f "$file" ]] || die "Codex auth file not found: $file"
  jq -e 'type == "object" and (.auth_mode | type == "string")' "$file" >/dev/null 2>&1 \
    || die "invalid Codex auth JSON: $file"
}

_codex_validate_provider_auth() {
  local file="$1"
  [[ -f "$file" ]] || die "Codex provider auth file not found: $file"
  jq -e '
    type == "object"
    and .auth_mode == "apikey"
    and (.OPENAI_API_KEY | type == "string" and length > 0)
  ' "$file" >/dev/null 2>&1 \
    || die "invalid Codex provider auth JSON: $file"
}

_codex_auth_is_chatgpt() {
  local file="$1"
  [[ -f "$file" ]] \
    && jq -e '.auth_mode == "chatgpt" and (.tokens | type == "object")' "$file" >/dev/null 2>&1
}

_codex_atomic_copy() {
  local src="$1" dst="$2" tmp
  tmp="$(dirname "$dst")/.ccs.$(basename "$dst").tmp.$$"
  cp "$src" "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$dst"
}

_codex_current_raw() {
  local current
  current="$(sed -nE 's/^model_provider[[:space:]]*=[[:space:]]*"([A-Za-z_][A-Za-z0-9_-]*)"[[:space:]]*$/\1/p' "$CODEX_CONFIG" | head -n 1)"
  printf '%s\n' "${current:-openai}"
}

_codex_provider_exists() {
  local name="$1"
  [[ "$name" == "openai" ]] && return 0
  grep -qE "^[[:space:]]*\[model_providers\.${name}\][[:space:]]*$" "$CODEX_CONFIG"
}

_codex_provider_names() {
  {
    echo openai
    sed -nE 's/^[[:space:]]*\[model_providers\.([A-Za-z_][A-Za-z0-9_-]*)\][[:space:]]*$/\1/p' "$CODEX_CONFIG"
  } | awk '!seen[$0]++'
}

_codex_provider_field() {
  local provider="$1" field="$2"
  [[ "$provider" == "openai" ]] && { [[ "$field" == "name" ]] && echo OpenAI; return; }
  awk -v section="model_providers.$provider" -v key="$field" '
    { header=$0; gsub(/[[:space:]]/, "", header) }
    header == "[" section "]" { inside=1; next }
    inside && header ~ /^\[/ { exit }
    inside && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line=$0; sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*\\\"", "", line)
      sub("\\\"[[:space:]]*$", "", line); print line; exit
    }
  ' "$CODEX_CONFIG"
}

_codex_toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

_codex_config_with_current() {
  local provider="$1" output="$2"
  awk -v provider="$provider" '
    BEGIN { replaced=0 }
    /^model_provider[[:space:]]*=/ && !replaced { print "model_provider = \"" provider "\""; replaced=1; next }
    { lines[++n]=$0 }
    END {
      if (!replaced) print "model_provider = \"" provider "\""
      for (i=1; i<=n; i++) print lines[i]
    }
  ' "$CODEX_CONFIG" > "$output"
}

_codex_config_without_provider() {
  local provider="$1" output="$2"
  awk -v section="model_providers.$provider" '
    { header=$0; gsub(/[[:space:]]/, "", header) }
    header == "[" section "]" || index(header, "[" section ".") == 1 { skip=1; next }
    skip && header ~ /^\[/ { skip=0 }
    !skip { print }
  ' "$CODEX_CONFIG" > "$output"
}

_codex_config_update_provider() {
  local provider="$1" display="$2" base_url="$3" wire_api="$4" output="$5"
  local command_path credential_path
  display="$(_codex_toml_escape "$display")"
  base_url="$(_codex_toml_escape "$base_url")"
  command_path="$(_codex_toml_escape "$(type -P jq)")"
  credential_path="$(_codex_toml_escape "$CODEX_AUTH_DIR/$provider.json")"
  awk \
    -v section="model_providers.$provider" \
    -v auth_section="model_providers.$provider.auth" \
    -v provider="$provider" \
    -v command_path="$command_path" \
    -v credential_path="$credential_path" \
    -v display="$display" \
    -v base_url="$base_url" \
    -v wire_api="$wire_api" '
    function missing_fields() {
      if (!seen_name) print "name = \"" display "\""
      if (!seen_base) print "base_url = \"" base_url "\""
      if (!seen_wire) print "wire_api = \"" wire_api "\""
      if (!seen_openai_auth) print "requires_openai_auth = false"
    }
    { header=$0; gsub(/[[:space:]]/, "", header) }
    skipping_auth && header !~ /^\[/ { next }
    skipping_auth { skipping_auth=0 }
    header == "[" auth_section "]" {
      if (inside) { missing_fields(); inside=0 }
      skipping_auth=1
      next
    }
    header == "[" section "]" {
      inside=1
      seen_name=seen_base=seen_wire=seen_openai_auth=0
      print
      next
    }
    inside && header ~ /^\[/ { missing_fields(); inside=0 }
    inside && /^[[:space:]]*name[[:space:]]*=/ { print "name = \"" display "\""; seen_name=1; next }
    inside && /^[[:space:]]*base_url[[:space:]]*=/ { print "base_url = \"" base_url "\""; seen_base=1; next }
    inside && /^[[:space:]]*wire_api[[:space:]]*=/ { print "wire_api = \"" wire_api "\""; seen_wire=1; next }
    inside && /^[[:space:]]*requires_openai_auth[[:space:]]*=/ {
      print "requires_openai_auth = false"
      seen_openai_auth=1
      next
    }
    inside && /^[[:space:]]*env_key[[:space:]]*=/ { next }
    inside && /^[[:space:]]*experimental_bearer_token[[:space:]]*=/ { next }
    { print }
    END {
      if (inside) missing_fields()
      print ""
      print "[" auth_section "]"
      print "command = \"" command_path "\""
      print "args = [\"-er\", \".OPENAI_API_KEY | strings | select(length > 0)\", \"" credential_path "\"]"
    }
  ' "$CODEX_CONFIG" > "$output"
}

_codex_append_provider() {
  local file="$1" provider="$2" display="$3" base_url="$4" wire_api="$5"
  local command_path credential_path
  command_path="$(_codex_toml_escape "$(type -P jq)")"
  credential_path="$(_codex_toml_escape "$CODEX_AUTH_DIR/$provider.json")"
  [[ ! -s "$file" || "$(tail -c 1 "$file" | wc -l | tr -d ' ')" != 0 ]] || printf '\n' >> "$file"
  [[ ! -s "$file" ]] || printf '\n' >> "$file"
  printf '[model_providers.%s]\nname = "%s"\nbase_url = "%s"\nwire_api = "%s"\nrequires_openai_auth = false\n\n' \
    "$provider" "$(_codex_toml_escape "$display")" "$(_codex_toml_escape "$base_url")" "$wire_api" >> "$file"
  printf '[model_providers.%s.auth]\ncommand = "%s"\nargs = ["-er", ".OPENAI_API_KEY | strings | select(length > 0)", "%s"]\n' \
    "$provider" "$command_path" "$credential_path" >> "$file"
}

_codex_write_api_auth() {
  local key="$1" output="$2"
  jq -n --arg key "$key" '{auth_mode:"apikey",OPENAI_API_KEY:$key}' > "$output"
  chmod 600 "$output"
}

_codex_read_legacy_value() {
  local file="$1" variable="$2" value
  value="$(sed -nE "s/^export[[:space:]]+${variable}=(.*)$/\\1/p" "$file" | tail -n 1)"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then value="${value:1:${#value}-2}"; fi
  if [[ "$value" == \'*\' && "$value" == *\' ]]; then value="${value:1:${#value}-2}"; fi
  printf '%s' "$value"
}

_codex_migrate_locked() {
  [[ -f "$CODEX_MIGRATION_MARKER" ]] && return 0
  _codex_require_jq

  if [[ -f "$CODEX_AUTH" ]]; then
    _codex_validate_auth "$CODEX_AUTH"
    if _codex_auth_is_chatgpt "$CODEX_AUTH"; then
      _codex_atomic_copy "$CODEX_AUTH" "$CODEX_AUTH_DIR/openai.json"
    fi
  fi

  local legacy_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ccs/codex/profiles"
  local legacy_state="${XDG_STATE_HOME:-$HOME/.local/state}/ccs/codex/current"
  local active="" file provider key tmp stamp backup display base_url wire_api config_tmp
  shopt -s nullglob
  if [[ -d "$legacy_dir" ]]; then
    for file in "$legacy_dir"/*.env; do
      provider="$(_codex_read_legacy_value "$file" CCS_CODEX_PROVIDER)"
      key="$(_codex_read_legacy_value "$file" OPENAI_API_KEY)"
      [[ -n "$provider" && "$provider" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ && -n "$key" ]] || continue
      tmp="$CODEX_AUTH_DIR/.ccs.$provider.json.tmp.$$"
      _codex_write_api_auth "$key" "$tmp"
      mv "$tmp" "$CODEX_AUTH_DIR/$provider.json"
      if _codex_provider_exists "$provider"; then
        display="$(_codex_provider_field "$provider" name)"
        base_url="$(_codex_provider_field "$provider" base_url)"
        wire_api="$(_codex_provider_field "$provider" wire_api)"
        config_tmp="$CODEX_DIR/.ccs.config.toml.tmp.$$"
        _codex_config_update_provider "$provider" "${display:-$provider}" "$base_url" "${wire_api:-responses}" "$config_tmp"
        mv "$config_tmp" "$CODEX_CONFIG"
      fi
    done
  fi

  if [[ -L "$legacy_state" ]]; then
    active="$(basename "$(readlink "$legacy_state")" .env)"
  fi
  if [[ -n "$active" && -f "$CODEX_AUTH_DIR/$active.json" ]] && _codex_provider_exists "$active"; then
    tmp="$CODEX_DIR/.ccs.config.toml.tmp.$$"
    _codex_config_with_current "$active" "$tmp"
    mv "$tmp" "$CODEX_CONFIG"
  fi

  # Upgrade CCS-managed v0.3 providers to independent command-backed auth.
  # Their protected snapshots remain in place, while global auth.json is
  # reserved for the official ChatGPT login used by Remote.
  while IFS= read -r provider; do
    [[ "$provider" != "openai" ]] || continue
    [[ -f "$CODEX_AUTH_DIR/$provider.json" ]] || continue
    _codex_validate_provider_auth "$CODEX_AUTH_DIR/$provider.json"
    display="$(_codex_provider_field "$provider" name)"
    base_url="$(_codex_provider_field "$provider" base_url)"
    wire_api="$(_codex_provider_field "$provider" wire_api)"
    config_tmp="$CODEX_DIR/.ccs.config.toml.tmp.$$"
    _codex_config_update_provider \
      "$provider" "${display:-$provider}" "$base_url" "${wire_api:-responses}" "$config_tmp"
    mv "$config_tmp" "$CODEX_CONFIG"
  done < <(_codex_provider_names)

  if _codex_auth_is_chatgpt "$CODEX_AUTH_DIR/openai.json" \
    && ! _codex_auth_is_chatgpt "$CODEX_AUTH"; then
    _codex_atomic_copy "$CODEX_AUTH_DIR/openai.json" "$CODEX_AUTH"
  fi

  stamp="$(date +%Y%m%d%H%M%S)"
  if [[ -d "$legacy_dir" ]]; then
    backup="$(dirname "$legacy_dir")/profiles.migrated-$stamp"
    mv "$legacy_dir" "$backup"
    chmod -R go-rwx,a-w "$backup"
    echo "✓ ccs: migrated legacy Codex profiles to $CODEX_AUTH_DIR" >&2
    echo "  read-only backup: $backup" >&2
  fi
  if [[ -L "$legacy_state" ]]; then
    mv "$legacy_state" "$(dirname "$legacy_state")/current.migrated-$stamp"
  fi
  : > "$CODEX_MIGRATION_MARKER"
  chmod 600 "$CODEX_MIGRATION_MARKER"
}

_codex_prepare() {
  _codex_require_jq
  _codex_init_dirs
  if [[ ! -f "$CODEX_MIGRATION_MARKER" ]]; then
    _codex_lock_acquire
    _codex_migrate_locked
    _codex_lock_release
  fi
}

_codex_read_secret() {
  local prompt="$1" value
  if [[ -t 0 ]]; then
    read -r -s -p "$prompt" value
    echo >&2
  else
    IFS= read -r value
  fi
  printf '%s' "$value"
}

_codex_native_login() {
  local binary auth_backup="" snapshot_backup="" config_tmp
  binary="$(type -P codex 2>/dev/null || true)"
  [[ -n "$binary" ]] || die "Codex CLI not found; install it before creating an OpenAI subscription login"

  _codex_lock_acquire
  if [[ -f "$CODEX_AUTH" ]]; then
    _codex_validate_auth "$CODEX_AUTH"
    if _codex_auth_is_chatgpt "$CODEX_AUTH"; then
      _codex_atomic_copy "$CODEX_AUTH" "$CODEX_AUTH_DIR/openai.json"
    fi
    auth_backup="$CODEX_DIR/.ccs.auth.json.login-backup.$$"
    cp "$CODEX_AUTH" "$auth_backup"
    chmod 600 "$auth_backup"
  fi
  if [[ -f "$CODEX_AUTH_DIR/openai.json" ]]; then
    snapshot_backup="$CODEX_AUTH_DIR/.ccs.openai.json.login-backup.$$"
    cp "$CODEX_AUTH_DIR/openai.json" "$snapshot_backup"
    chmod 600 "$snapshot_backup"
  fi

  echo "ccs: starting the official Codex ChatGPT login..." >&2
  if ! "$binary" login -c 'model_provider="openai"'; then
    if [[ -n "$auth_backup" ]]; then mv "$auth_backup" "$CODEX_AUTH"; else rm -f "$CODEX_AUTH"; fi
    [[ -z "$snapshot_backup" ]] || mv "$snapshot_backup" "$CODEX_AUTH_DIR/openai.json"
    die "official Codex login did not complete"
  fi
  if ! jq -e '.auth_mode == "chatgpt" and (.tokens | type == "object")' "$CODEX_AUTH" >/dev/null 2>&1; then
    if [[ -n "$auth_backup" ]]; then mv "$auth_backup" "$CODEX_AUTH"; else rm -f "$CODEX_AUTH"; fi
    [[ -z "$snapshot_backup" ]] || mv "$snapshot_backup" "$CODEX_AUTH_DIR/openai.json"
    die "Codex login did not create a ChatGPT subscription credential; previous auth was restored"
  fi

  _codex_atomic_copy "$CODEX_AUTH" "$CODEX_AUTH_DIR/openai.json"
  config_tmp="$CODEX_DIR/.ccs.config.toml.tmp.$$"
  _codex_config_with_current openai "$config_tmp"
  if ! mv "$config_tmp" "$CODEX_CONFIG"; then
    if [[ -n "$auth_backup" ]]; then mv "$auth_backup" "$CODEX_AUTH"; else rm -f "$CODEX_AUTH"; fi
    if [[ -n "$snapshot_backup" ]]; then mv "$snapshot_backup" "$CODEX_AUTH_DIR/openai.json"; else rm -f "$CODEX_AUTH_DIR/openai.json"; fi
    die "failed to update $CODEX_CONFIG; previous auth was restored"
  fi
  [[ -z "$auth_backup" || ! -f "$auth_backup" ]] || rm -f "$auth_backup"
  [[ -z "$snapshot_backup" || ! -f "$snapshot_backup" ]] || rm -f "$snapshot_backup"
  _codex_lock_release
  echo "✓ ccs: OpenAI subscription login is active and managed"
}

cmd_codex_current() { _codex_prepare; _codex_current_raw; }

cmd_codex_list() {
  _codex_prepare
  local current name max=0
  local names=()
  current="$(_codex_current_raw)"
  while IFS= read -r name; do names+=("$name"); ((${#name} > max)) && max=${#name}; done < <(_codex_provider_names)
  for name in "${names[@]}"; do
    printf '  %-*s  %s%s\n' "$max" "$name" \
      "$([[ "$name" == "$current" ]] && echo '* active' || echo '        ')" \
      "$([[ -f "$CODEX_AUTH_DIR/$name.json" ]] && echo '  auth: saved' || echo '  auth: missing')"
  done
}

cmd_codex_show() {
  _codex_prepare
  local name="${1:-}" snapshot
  name="${name:-$(_codex_current_raw)}"
  snapshot="$CODEX_AUTH_DIR/$name.json"
  _codex_provider_exists "$name" || die "Codex provider '$name' not found"
  echo "provider: $name"
  [[ "$name" == "$(_codex_current_raw)" ]] && echo "active:   yes" || echo "active:   no"
  if [[ "$name" != "openai" ]]; then
    echo "name:     $(_codex_provider_field "$name" name)"
    echo "base_url: $(_codex_provider_field "$name" base_url)"
    echo "wire_api: $(_codex_provider_field "$name" wire_api)"
  fi
  if [[ -f "$snapshot" ]]; then
    _codex_validate_auth "$snapshot"
    echo "auth:     $(jq -r '.auth_mode' "$snapshot")"
    [[ "$(jq -r 'has("OPENAI_API_KEY") and (.OPENAI_API_KEY != null and .OPENAI_API_KEY != "")' "$snapshot")" == true ]] && echo "api_key:  ***"
    [[ "$(jq -r 'has("tokens") and (.tokens != null)' "$snapshot")" == true ]] && echo "tokens:   saved"
  else
    echo "auth:     missing"
  fi
  return 0
}

cmd_codex_new() {
  _codex_prepare
  local provider="${1:-}" display base_url wire_api key config_tmp auth_tmp
  [[ -n "$provider" ]] || die "usage: ccs codex new <provider>"
  if [[ "$provider" == "openai" ]]; then
    [[ ! -f "$CODEX_AUTH_DIR/openai.json" ]] || die "OpenAI auth is already managed; run 'ccs codex login' to sign in again"
    _codex_native_login
    return 0
  fi
  [[ "$provider" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ && "$provider" != "openai" ]] || die "invalid Codex provider name '$provider'"
  _codex_provider_exists "$provider" && die "Codex provider '$provider' already exists"

  read -r -p "Display name [$provider]: " display
  display="${display:-$provider}"
  read -r -p "Base URL: " base_url
  [[ -n "$base_url" ]] || die "Base URL is required"
  read -r -p "Wire API [responses]: " wire_api
  wire_api="${wire_api:-responses}"
  [[ "$wire_api" == "responses" || "$wire_api" == "chat" ]] || die "wire API must be 'responses' or 'chat'"
  key="$(_codex_read_secret 'API key: ')"
  [[ -n "$key" ]] || die "API key is required"

  _codex_lock_acquire
  _codex_provider_exists "$provider" && die "Codex provider '$provider' already exists"
  [[ ! -e "$CODEX_AUTH_DIR/$provider.json" ]] || die "Codex auth snapshot '$provider' already exists"
  config_tmp="$CODEX_DIR/.ccs.config.toml.tmp.$$"
  auth_tmp="$CODEX_AUTH_DIR/.ccs.$provider.json.tmp.$$"
  cp "$CODEX_CONFIG" "$config_tmp"
  _codex_append_provider "$config_tmp" "$provider" "$display" "$base_url" "$wire_api"
  _codex_write_api_auth "$key" "$auth_tmp"
  mv "$auth_tmp" "$CODEX_AUTH_DIR/$provider.json"
  if ! mv "$config_tmp" "$CODEX_CONFIG"; then
    rm -f "$CODEX_AUTH_DIR/$provider.json"
    die "failed to update $CODEX_CONFIG; provider auth was removed"
  fi
  chmod 600 "$CODEX_AUTH_DIR/$provider.json"
  _codex_lock_release
  echo "✓ ccs: created Codex provider '$provider'"
  echo "  switch with: ccs codex use $provider"
}

cmd_codex_use() {
  _codex_prepare
  local target="${1:-}" config_tmp auth_backup="" auth_was_missing=0
  [[ -n "$target" ]] || die "usage: ccs codex use <provider>"
  _codex_provider_exists "$target" || die "Codex provider '$target' not found"
  if [[ "$target" == "openai" ]]; then
    _codex_validate_auth "$CODEX_AUTH_DIR/openai.json"
    _codex_auth_is_chatgpt "$CODEX_AUTH_DIR/openai.json" \
      || die "OpenAI snapshot is not a ChatGPT login; run 'ccs codex login'"
  else
    _codex_validate_provider_auth "$CODEX_AUTH_DIR/$target.json"
  fi

  _codex_lock_acquire
  _codex_provider_exists "$target" || die "Codex provider '$target' not found"
  if [[ "$target" == "openai" ]]; then
    _codex_auth_is_chatgpt "$CODEX_AUTH_DIR/openai.json" \
      || die "OpenAI snapshot is not a ChatGPT login; run 'ccs codex login'"
  else
    _codex_validate_provider_auth "$CODEX_AUTH_DIR/$target.json"
  fi

  if [[ -f "$CODEX_AUTH" ]]; then
    _codex_validate_auth "$CODEX_AUTH"
    if _codex_auth_is_chatgpt "$CODEX_AUTH"; then
      _codex_atomic_copy "$CODEX_AUTH" "$CODEX_AUTH_DIR/openai.json"
    fi
  fi

  if ! _codex_auth_is_chatgpt "$CODEX_AUTH" \
    && _codex_auth_is_chatgpt "$CODEX_AUTH_DIR/openai.json"; then
    if [[ -f "$CODEX_AUTH" ]]; then
      auth_backup="$CODEX_DIR/.ccs.auth.json.backup.$$"
      cp "$CODEX_AUTH" "$auth_backup"
      chmod 600 "$auth_backup"
    else
      auth_was_missing=1
    fi
    _codex_atomic_copy "$CODEX_AUTH_DIR/openai.json" "$CODEX_AUTH"
  fi

  if [[ "$target" == "openai" ]] && ! _codex_auth_is_chatgpt "$CODEX_AUTH"; then
    die "ChatGPT login is unavailable; run 'ccs codex login'"
  fi

  config_tmp="$CODEX_DIR/.ccs.config.toml.tmp.$$"
  _codex_config_with_current "$target" "$config_tmp"
  if ! mv "$config_tmp" "$CODEX_CONFIG"; then
    if [[ -n "$auth_backup" ]]; then
      mv "$auth_backup" "$CODEX_AUTH"
    elif ((auth_was_missing)); then
      rm -f "$CODEX_AUTH"
    fi
    die "failed to update $CODEX_CONFIG"
  fi
  [[ -z "$auth_backup" ]] || rm -f "$auth_backup"
  _codex_lock_release
  echo "✓ ccs: switched Codex to '$target'"
  if [[ "$target" != "openai" ]] && ! _codex_auth_is_chatgpt "$CODEX_AUTH"; then
    echo "  note: ChatGPT login is unavailable; Remote requires 'ccs codex login'"
  fi
}

cmd_codex_edit() {
  _codex_prepare
  local provider="${1:-}" display base_url wire_api new_key config_tmp auth_tmp auth_backup=""
  [[ -n "$provider" ]] || die "usage: ccs codex edit <provider>"
  [[ "$provider" != "openai" ]] || die "the built-in 'openai' provider cannot be edited"
  _codex_provider_exists "$provider" || die "Codex provider '$provider' not found"
  display="$(_codex_provider_field "$provider" name)"
  base_url="$(_codex_provider_field "$provider" base_url)"
  wire_api="$(_codex_provider_field "$provider" wire_api)"
  local answer
  read -r -p "Display name [$display]: " answer; display="${answer:-$display}"
  read -r -p "Base URL [$base_url]: " answer; base_url="${answer:-$base_url}"
  read -r -p "Wire API [$wire_api]: " answer; wire_api="${answer:-$wire_api}"
  [[ "$wire_api" == "responses" || "$wire_api" == "chat" ]] || die "wire API must be 'responses' or 'chat'"
  new_key="$(_codex_read_secret 'New API key (leave blank to keep current): ')"
  [[ -f "$CODEX_AUTH_DIR/$provider.json" || -n "$new_key" ]] || die "API key is required because this provider has no auth snapshot"

  _codex_lock_acquire
  _codex_provider_exists "$provider" || die "Codex provider '$provider' not found"
  config_tmp="$CODEX_DIR/.ccs.config.toml.tmp.$$"
  _codex_config_update_provider "$provider" "$display" "$base_url" "$wire_api" "$config_tmp"
  if [[ -n "$new_key" ]]; then
    auth_tmp="$CODEX_AUTH_DIR/.ccs.$provider.json.tmp.$$"
    auth_backup="$CODEX_AUTH_DIR/.ccs.$provider.json.backup.$$"
    [[ ! -f "$CODEX_AUTH_DIR/$provider.json" ]] || cp "$CODEX_AUTH_DIR/$provider.json" "$auth_backup"
    _codex_write_api_auth "$new_key" "$auth_tmp"
    mv "$auth_tmp" "$CODEX_AUTH_DIR/$provider.json"
  fi
  if ! mv "$config_tmp" "$CODEX_CONFIG"; then
    if [[ -n "$auth_backup" && -f "$auth_backup" ]]; then
      mv "$auth_backup" "$CODEX_AUTH_DIR/$provider.json"
    elif [[ -n "$new_key" ]]; then
      rm -f "$CODEX_AUTH_DIR/$provider.json"
    fi
    die "failed to update $CODEX_CONFIG; provider auth was restored"
  fi
  [[ -z "$auth_backup" || ! -f "$auth_backup" ]] || rm -f "$auth_backup"
  _codex_lock_release
  echo "✓ ccs: updated Codex provider '$provider'"
}

cmd_codex_rm() {
  _codex_prepare
  local provider="${1:-}" answer config_tmp auth_backup=""
  [[ -n "$provider" ]] || die "usage: ccs codex rm <provider>"
  [[ "$provider" != "openai" ]] || die "the built-in 'openai' provider cannot be removed"
  _codex_provider_exists "$provider" || die "Codex provider '$provider' not found"
  [[ "$provider" != "$(_codex_current_raw)" ]] || die "cannot remove active provider '$provider'; switch first"
  read -r -p "Remove Codex provider '$provider'? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Cancelled."; return 0; }
  _codex_lock_acquire
  _codex_provider_exists "$provider" || die "Codex provider '$provider' not found"
  [[ "$provider" != "$(_codex_current_raw)" ]] || die "cannot remove active provider '$provider'; switch first"
  config_tmp="$CODEX_DIR/.ccs.config.toml.tmp.$$"
  _codex_config_without_provider "$provider" "$config_tmp"
  if [[ -f "$CODEX_AUTH_DIR/$provider.json" ]]; then
    auth_backup="$CODEX_AUTH_DIR/.ccs.$provider.json.removed.$$"
    mv "$CODEX_AUTH_DIR/$provider.json" "$auth_backup"
  fi
  if ! mv "$config_tmp" "$CODEX_CONFIG"; then
    [[ -z "$auth_backup" ]] || mv "$auth_backup" "$CODEX_AUTH_DIR/$provider.json"
    die "failed to update $CODEX_CONFIG; provider auth was restored"
  fi
  [[ -z "$auth_backup" ]] || rm -f "$auth_backup"
  _codex_lock_release
  echo "✓ ccs: removed Codex provider '$provider'"
}

cmd_codex_removed() {
  die "'ccs codex $1' was removed in v0.3; provider switching now updates ~/.codex/config.toml directly"
}

cmd_codex_login() {
  _codex_prepare
  _codex_native_login
}

cmd_codex_help() {
  cat <<EOF
ccs codex — manage Codex providers without shell environment variables

Usage:
  ccs codex list              List providers and saved auth
  ccs codex current           Show the active provider
  ccs codex use <name>        Switch providers while keeping ChatGPT auth
  ccs codex new <provider>    Create a provider interactively
  ccs codex new openai        Create an official ChatGPT subscription login
  ccs codex login             Sign in to OpenAI again and refresh its snapshot
  ccs codex edit <name>       Edit provider settings and optionally its API key
  ccs codex rm <name>         Remove an inactive provider
  ccs codex show [<name>]     Show provider metadata (secrets masked)

Files:
  Config:       $CODEX_CONFIG
  ChatGPT auth: $CODEX_AUTH
  Auth store:   $CODEX_AUTH_DIR
EOF
}

cmd_codex() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list|ls) cmd_codex_list ;; current|c) cmd_codex_current ;;
    use|sw|switch) cmd_codex_use "$@" ;; new|create) cmd_codex_new "$@" ;;
    login) cmd_codex_login ;;
    edit|e) cmd_codex_edit "$@" ;; rm|remove) cmd_codex_rm "$@" ;;
    show) cmd_codex_show "$@" ;;
    env|source|src|unset|off|path) cmd_codex_removed "$sub" ;;
    help|-h|--help) cmd_codex_help ;; *) die "ccs codex: unknown command '$sub'" ;;
  esac
}

cmd_update() {
  if [[ "${1:-}" == "--version" ]]; then
    local remote_sha local_sha
    remote_sha=$(curl -fsSL "$REPO/ccs.sh" | shasum -a 256 | cut -d' ' -f1)
    local_sha=$(shasum -a 256 "$XDG_CONFIG_HOME/ccs/ccs.sh" | cut -d' ' -f1)
    if [[ "$remote_sha" == "$local_sha" ]]; then
      echo "ccs is up to date (sha256 ${local_sha:0:7})"
    else
      echo "update available — run: ccs update"
    fi
    return
  fi
  curl -fsSL "$REPO/install.sh" | bash
}

cmd_help() {
  cat <<EOF
ccs — Claude Code Switch

Usage:
  ccs list              List profiles (current one highlighted)
  ccs current           Show active profile name
  ccs use <name>        Switch to profile (current terminal + persist)
  ccs env <name>        Source profile in current terminal only (alias: source)
  ccs new <name>        Create a new profile (opens \$EDITOR)
  ccs edit <name>       Edit an existing profile
  ccs rm <name>         Remove a profile
  ccs show [<name>]     Show a profile's env file (sensitive keys masked)
  ccs statusline        List statusline bindings
  ccs statusline bind <name>   Bind a statusline to a profile
  ccs statusline unbind <name> Remove a statusline binding
  ccs statusline show <name>   Show a profile's statusline
  ccs unset             Clear all Claude Code env vars
  ccs update            Update ccs to latest version
  ccs path              Print profiles directory
  ccs version           Print version
  ccs codex ...         Manage Codex provider files (run 'ccs codex help')
  ccs help              This message

Profiles: $CCS_DIR
State:    $CURRENT
Codex config:   $CODEX_CONFIG
Codex auth:     $CODEX_AUTH
Version:  $VERSION
EOF
}

cmd_statusline() {
  local sub="${1:-}"; shift 2>/dev/null || true

  case "$sub" in
    bind)
      local name="${1:-}"; shift 2>/dev/null || true
      [[ -z "$name" ]] && die "usage: ccs statusline bind <profile> [--command \"...\"]"
      local profile="$CCS_DIR/$name.env"
      [[ -f "$profile" ]] || die "profile '$name' not found — create it first: ccs new $name"
      local sl_file="$CCS_DIR/$name.statusline"

      # --command flag: write directly, skip editor
      if [[ "${1:-}" == "--command" ]]; then
        local cmd="${2:-}"
        [[ -z "$cmd" ]] && die "--command requires an argument"
        printf '%s\n' "$cmd" > "$sl_file"
        echo "✓ ccs: statusline bound to '$name'" >&2
        return
      fi

      # New file: write a template first
      if [[ ! -f "$sl_file" ]]; then
        cat > "$sl_file" <<'INNEREOF'
# Statusline for REPLACE_ME — edit freely.
# Claude Code sends session JSON via stdin.
input=$(cat 2>/dev/null || true)
model=$(echo "$input" | jq -r '.model.display_name // ""' 2>/dev/null || true)
if [[ -n "$model" ]]; then
  printf '\033[1;36mccs:REPLACE_ME\033[0m \033[90m[%s]\033[0m\n' "$model"
else
  printf '\033[1;36mccs:REPLACE_ME\033[0m\n'
fi
INNEREOF
        # Replace placeholder with actual profile name
        sed -i '' "s/REPLACE_ME/$name/g" "$sl_file"
      fi
      ${EDITOR:-vim} "$sl_file"
      echo "✓ ccs: statusline bound to '$name'" >&2
      ;;

    unbind)
      local name="${1:-}"; [[ -z "$name" ]] && die "usage: ccs statusline unbind <profile>"
      local sl_file="$CCS_DIR/$name.statusline"
      [[ -f "$sl_file" ]] || die "no statusline bound to '$name'"
      rm "$sl_file"
      echo "✓ ccs: statusline unbound from '$name'" >&2
      ;;

    show)
      local name="${1:-}"; [[ -z "$name" ]] && die "usage: ccs statusline show <profile>"
      local sl_file="$CCS_DIR/$name.statusline"
      [[ -f "$sl_file" ]] || die "no statusline bound to '$name'"
      echo "--- $name.statusline ---"
      cat "$sl_file"
      ;;

    "")
      shopt -s nullglob
      local files=("$CCS_DIR"/*.statusline)
      if ((${#files[@]} == 0)); then
        echo "No statusline bindings in $CCS_DIR"
        echo "Bind one with: ccs statusline bind <profile>"
        return
      fi
      local max=0 fname
      for f in "${files[@]}"; do
        fname="$(basename "$f" .statusline)"
        ((${#fname} > max)) && max=${#fname}
      done
      for f in "${files[@]}"; do
        fname="$(basename "$f" .statusline)"
        printf "  %-*s\n" "$max" "$fname"
      done
      ;;

    *) die "ccs statusline: unknown subcommand '$sub' — use: bind, unbind, show" ;;
  esac
}

# ── dispatch ─────────────────────────────────────────────────────────

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
  list|ls)              cmd_list ;;
  current|c)            cmd_current ;;
  use|sw|switch)        cmd_use "$@" ;;
  env|source|src)       cmd_source "$@" ;;
  new|create)           cmd_new "$@" ;;
  edit|e)               cmd_edit "$@" ;;
  rm|remove)            cmd_rm "$@" ;;
  unset|off)            cmd_unset ;;
  show)                 cmd_show "$@" ;;
  path)                 echo "$CCS_DIR" ;;
  update)               cmd_update "$@" ;;
  version|-V|--version) echo "ccs $VERSION" ;;
  statusline)           cmd_statusline "$@" ;;
  codex)                cmd_codex "$@" ;;
  help|-h|--help)       cmd_help ;;
  *)                    echo "ccs: unknown command '$cmd' — run \`ccs help\` for usage" >&2; exit 1 ;;
esac
