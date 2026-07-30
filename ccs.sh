#!/bin/bash
# ccs — Claude Code Switch
# https://github.com/zzzhizhia/ccs
# Standalone script. The thin shell wrapper evals stdout only for Claude
# use/env/source/unset so those commands affect the calling shell. Codex
# provider commands update ~/.codex files directly and never need eval.

set -euo pipefail

VERSION="0.6.1"
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
CODEX_PROVIDER_DIR="$CODEX_DIR/ccs-providers"
CODEX_PROVIDER_CURRENT="$CODEX_PROVIDER_DIR/current"
CODEX_BACKUP_DIR="$CODEX_DIR/ccs-backups"
CODEX_LOCK="$CODEX_DIR/.ccs.lock"
CODEX_MIGRATION_MARKER="$CODEX_AUTH_DIR/.migrated-v2"
CODEX_FIXED_MIGRATION_MARKER="$CODEX_PROVIDER_DIR/.migrated-v3"
CODEX_LOCK_HELD=0
CODEX_TEMP_FILES=()
CODEX_TEMP_DIRS=()
CODEX_TX_ACTIVE=0
CODEX_TX_TARGETS=()
CODEX_TX_BACKUPS=()
CODEX_TX_CREATED_DIRS=()

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

cmd_rename() {
  local old="${1:-}" new="${2:-}"
  [[ $# -eq 2 && -n "$old" && -n "$new" ]] || die "usage: ccs rename <old> <new>"
  [[ "$old" != */* && "$old" != "." && "$old" != ".." ]] || die "invalid profile name '$old'"
  [[ "$new" != */* && "$new" != "." && "$new" != ".." ]] || die "invalid profile name '$new'"
  [[ "$old" != "$new" ]] || die "the new profile name must be different"

  local old_profile="$CCS_DIR/$old.env" new_profile="$CCS_DIR/$new.env"
  local old_statusline="$CCS_DIR/$old.statusline" new_statusline="$CCS_DIR/$new.statusline"
  local active=0 statusline_moved=0
  [[ -f "$old_profile" ]] || die "profile '$old' not found"
  [[ ! -e "$new_profile" && ! -L "$new_profile" ]] || die "profile '$new' already exists"
  [[ ! -e "$new_statusline" && ! -L "$new_statusline" ]] || die "statusline binding '$new' already exists"
  [[ "$(cmd_current)" == "$old" ]] && active=1

  mv "$old_profile" "$new_profile"
  if [[ -f "$old_statusline" ]]; then
    if ! mv "$old_statusline" "$new_statusline"; then
      mv "$new_profile" "$old_profile"
      die "failed to rename statusline binding; profile rename was rolled back"
    fi
    statusline_moved=1
  fi
  if ((active)); then
    if ! ln -sfn "$new_profile" "$CURRENT"; then
      ((statusline_moved)) && mv "$new_statusline" "$old_statusline"
      mv "$new_profile" "$old_profile"
      die "failed to update the active profile; rename was rolled back"
    fi
    if ((statusline_moved)) && ! _apply_profile_statusline "$new"; then
      echo "ccs: warning: profile renamed, but the active statusline could not be refreshed" >&2
    fi
  fi

  echo "✓ ccs: renamed profile '$old' to '$new'"
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

_codex_transaction_rollback() {
  ((CODEX_TX_ACTIVE)) || return 0
  local index target backup dir
  if [[ ${CODEX_TX_TARGETS[0]+_} ]]; then
    for ((index=${#CODEX_TX_TARGETS[@]} - 1; index>=0; index--)); do
      target="${CODEX_TX_TARGETS[$index]}"
      backup="${CODEX_TX_BACKUPS[$index]}"
      rm -f "$target" 2>/dev/null || true
      if [[ -n "$backup" && ( -e "$backup" || -L "$backup" ) ]]; then
        cp -Pp "$backup" "$target" 2>/dev/null || true
      fi
    done
  fi
  if [[ ${CODEX_TX_CREATED_DIRS[0]+_} ]]; then
    for ((index=${#CODEX_TX_CREATED_DIRS[@]} - 1; index>=0; index--)); do
      dir="${CODEX_TX_CREATED_DIRS[$index]}"
      [[ -d "$dir" ]] && rm -rf "$dir"
    done
  fi
  if [[ ${CODEX_TX_BACKUPS[0]+_} ]]; then
    for backup in "${CODEX_TX_BACKUPS[@]}"; do
      [[ -z "$backup" ]] || rm -f "$backup"
    done
  fi
  CODEX_TX_ACTIVE=0
  CODEX_TX_TARGETS=()
  CODEX_TX_BACKUPS=()
  CODEX_TX_CREATED_DIRS=()
}

_codex_transaction_begin() {
  ((CODEX_TX_ACTIVE == 0)) || die "internal Codex transaction is already active"
  CODEX_TX_ACTIVE=1
  CODEX_TX_TARGETS=()
  CODEX_TX_BACKUPS=()
  CODEX_TX_CREATED_DIRS=()
  _codex_install_cleanup_trap
}

_codex_transaction_track() {
  local target="$1" backup=""
  if [[ -e "$target" || -L "$target" ]]; then
    backup="$(mktemp "$CODEX_DIR/.ccs.transaction.XXXXXX")"
    _codex_register_temp "$backup"
    rm -f "$backup"
    cp -Pp "$target" "$backup"
    chmod 600 "$backup" 2>/dev/null || true
  fi
  CODEX_TX_TARGETS+=("$target")
  CODEX_TX_BACKUPS+=("$backup")
}

_codex_transaction_track_created_dir() {
  local dir="$1"
  [[ ! -e "$dir" && ! -L "$dir" ]] || die "transaction directory already exists: $dir"
  CODEX_TX_CREATED_DIRS+=("$dir")
}

_codex_transaction_commit() {
  local backup
  if [[ ${CODEX_TX_BACKUPS[0]+_} ]]; then
    for backup in "${CODEX_TX_BACKUPS[@]}"; do
      [[ -z "$backup" ]] || rm -f "$backup"
    done
  fi
  CODEX_TX_ACTIVE=0
  CODEX_TX_TARGETS=()
  CODEX_TX_BACKUPS=()
  CODEX_TX_CREATED_DIRS=()
}

_codex_cleanup() {
  local file dir
  _codex_transaction_rollback
  if [[ ${CODEX_TEMP_FILES[0]+_} ]]; then
    for file in "${CODEX_TEMP_FILES[@]}"; do rm -f "$file"; done
  fi
  if [[ ${CODEX_TEMP_DIRS[0]+_} ]]; then
    for dir in "${CODEX_TEMP_DIRS[@]}"; do [[ -d "$dir" ]] && rm -rf "$dir"; done
  fi
  if ((CODEX_LOCK_HELD)); then
    rmdir "$CODEX_LOCK" 2>/dev/null || true
    CODEX_LOCK_HELD=0
  fi
}

_codex_install_cleanup_trap() {
  trap '_codex_cleanup' EXIT
  trap '_codex_cleanup; exit 130' HUP INT TERM
}

_codex_register_temp() {
  CODEX_TEMP_FILES+=("$1")
  _codex_install_cleanup_trap
}

_codex_register_temp_dir() {
  CODEX_TEMP_DIRS+=("$1")
  _codex_install_cleanup_trap
}

_codex_lock_acquire() {
  _codex_init_dirs
  if ! mkdir "$CODEX_LOCK" 2>/dev/null; then
    die "another ccs codex operation is running (lock: $CODEX_LOCK)"
  fi
  CODEX_LOCK_HELD=1
  _codex_install_cleanup_trap
}

_codex_lock_release() {
  if ((CODEX_LOCK_HELD)); then
    rmdir "$CODEX_LOCK" 2>/dev/null || true
    CODEX_LOCK_HELD=0
  fi
  [[ ${CODEX_TEMP_FILES[0]+_} ]] || trap - EXIT HUP INT TERM
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
  _codex_register_temp "$tmp"
  cp "$src" "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$dst"
}

_codex_config_current_raw() {
  local current
  current="$(sed -nE 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"([A-Za-z_][A-Za-z0-9_-]*)"[[:space:]]*$/\1/p' "$CODEX_CONFIG" | head -n 1)"
  printf '%s\n' "${current:-openai}"
}

_codex_config_provider_exists() {
  local name="$1"
  [[ "$name" == "openai" ]] && return 0
  grep -qE "^[[:space:]]*\[model_providers\.${name}\][[:space:]]*(#.*)?$" "$CODEX_CONFIG"
}

_codex_config_provider_names() {
  {
    echo openai
    sed -nE 's/^[[:space:]]*\[model_providers\.([A-Za-z_][A-Za-z0-9_-]*)\][[:space:]]*(#.*)?$/\1/p' "$CODEX_CONFIG"
  } | awk '!seen[$0]++'
}

_codex_config_provider_field() {
  local provider="$1" field="$2"
  [[ "$provider" == "openai" ]] && { [[ "$field" == "name" ]] && echo OpenAI; return; }
  awk -v section="model_providers.$provider" -v key="$field" '
    { header=$0; sub(/[[:space:]]*#.*/, "", header); gsub(/[[:space:]]/, "", header) }
    header == "[" section "]" { inside=1; next }
    inside && header ~ /^\[/ { exit }
    inside && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line=$0
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
      sub(/[[:space:]]+#.*/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      quote=substr(line, 1, 1)
      if ((quote == "\"" || quote == sprintf("%c", 39)) && substr(line, length(line), 1) == quote) {
        line=substr(line, 2, length(line) - 2)
      }
      print line
      exit
    }
  ' "$CODEX_CONFIG"
}

_codex_provider_path() {
  printf '%s/%s.toml\n' "$CODEX_PROVIDER_DIR" "$1"
}

_codex_current_raw() {
  local link name
  [[ -L "$CODEX_PROVIDER_CURRENT" ]] || die "Codex logical provider current link is missing"
  link="$(readlink "$CODEX_PROVIDER_CURRENT")"
  name="$(basename "$link" .toml)"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ && "$link" == *.toml ]] \
    || die "invalid Codex logical provider current link"
  [[ -f "$CODEX_PROVIDER_DIR/$name.toml" ]] \
    || die "active Codex logical provider '$name' is missing"
  printf '%s\n' "$name"
}

_codex_provider_exists() {
  [[ -f "$(_codex_provider_path "$1")" ]]
}

_codex_provider_names() {
  local file
  shopt -s nullglob
  for file in "$CODEX_PROVIDER_DIR"/*.toml; do
    basename "$file" .toml
  done | sort
}

_codex_provider_field() {
  local provider="$1" field="$2" file
  file="$(_codex_provider_path "$provider")"
  [[ -f "$file" ]] || return 1
  awk -v section="model_providers.$provider" -v key="$field" '
    { header=$0; sub(/[[:space:]]*#.*/, "", header); gsub(/[[:space:]]/, "", header) }
    header == "[" section "]" { inside=1; next }
    inside && header ~ /^\[/ { exit }
    inside && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line=$0
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
      sub(/[[:space:]]+#.*/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      quote=substr(line, 1, 1)
      if ((quote == "\"" || quote == sprintf("%c", 39)) && substr(line, length(line), 1) == quote) {
        line=substr(line, 2, length(line) - 2)
      }
      print line
      exit
    }
  ' "$file"
}

_codex_toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

_codex_config_file_with_current() {
  local input="$1" provider="$2" output="$3"
  awk -v provider="$provider" '
    BEGIN { replaced=0 }
    /^[[:space:]]*model_provider[[:space:]]*=/ {
      if (!replaced) print "model_provider = \"" provider "\""
      replaced=1
      next
    }
    { lines[++n]=$0 }
    END {
      if (!replaced) print "model_provider = \"" provider "\""
      for (i=1; i<=n; i++) print lines[i]
    }
  ' "$input" > "$output"
}

_codex_config_with_current() {
  local provider="$1" output="$2"
  _codex_config_file_with_current "$CODEX_CONFIG" "$provider" "$output"
}

_codex_config_without_provider() {
  local provider="$1" output="$2"
  _codex_config_file_without_provider "$CODEX_CONFIG" "$provider" "$output"
}

_codex_config_file_without_provider() {
  local input="$1" provider="$2" output="$3"
  awk -v section="model_providers.$provider" '
    { header=$0; sub(/[[:space:]]*#.*/, "", header); gsub(/[[:space:]]/, "", header) }
    header == "[" section "]" || index(header, "[" section ".") == 1 { skip=1; next }
    skip && header ~ /^\[/ { skip=0 }
    !skip { print }
  ' "$input" > "$output"
}

_codex_config_file_without_all_providers() {
  local input="$1" output="$2"
  awk '
    {
      header=$0
      sub(/[[:space:]]*#.*/, "", header)
      gsub(/[[:space:]]/, "", header)
    }
    header ~ /^\[model_providers\.[A-Za-z_][A-Za-z0-9_-]*(\..*)?\]$/ { skip=1; next }
    skip && header ~ /^\[/ { skip=0 }
    !skip { print }
  ' "$input" > "$output"
}

_codex_extract_provider_fragment() {
  local provider="$1" input="$2" output="$3"
  awk \
    -v section="model_providers.$provider" \
    -v auth_section="model_providers.$provider.auth" '
    {
      header=$0
      sub(/[[:space:]]*#.*/, "", header)
      gsub(/[[:space:]]/, "", header)
    }
    header ~ /^\[/ {
      include=(header == "[" section "]" || index(header, "[" section ".") == 1)
      if (header == "[" auth_section "]" || index(header, "[" auth_section ".") == 1) {
        include=0
      }
    }
    include { print }
  ' "$input" > "$output"
}

_codex_file_fingerprint() {
  cksum "$1" | awk '{ print $1 ":" $2 }'
}

_codex_validate_provider_fragment() {
  local provider="$1" file="$2" result
  result="$(
    awk -v section="model_providers.$provider" '
      function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
      }
      function clean_value(value, quote, i, char, escaped, tail) {
        value=trim(value)
        quote=substr(value, 1, 1)
        if (quote == "\"" || quote == sprintf("%c", 39)) {
          escaped=0
          for (i=2; i<=length(value); i++) {
            char=substr(value, i, 1)
            if (char == quote && !escaped) {
              tail=trim(substr(value, i + 1))
              if (tail == "" || substr(tail, 1, 1) == "#") return substr(value, 1, i)
              return "__CCS_INVALID_VALUE__"
            }
            if (char == "\\" && !escaped) escaped=1
            else escaped=0
          }
        }
        sub(/[[:space:]]+#.*/, "", value)
        return trim(value)
      }
      function field_value(key, line, value) {
        value=line
        sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
        return clean_value(value)
      }
      function quoted_nonempty(value, quote, inner) {
        if (length(value) < 3) return 0
        quote=substr(value, 1, 1)
        inner=substr(value, 2, length(value) - 2)
        return (quote == "\"" || quote == sprintf("%c", 39)) \
          && substr(value, length(value), 1) == quote \
          && inner ~ /[^[:space:]]/
      }
      {
        header=$0
        sub(/[[:space:]]*#.*/, "", header)
        gsub(/[[:space:]]/, "", header)
      }
      header ~ /^\[/ {
        if (header == "[" section "]") {
          main_count++
          inside=1
          seen_main=1
        } else if (index(header, "[" section ".") == 1) {
          if (!seen_main) bad_order=1
          if (header == "[" section ".auth]" || index(header, "[" section ".auth.") == 1) {
            auth_table=1
          }
          inside=0
        } else {
          other_table=1
          inside=0
        }
        next
      }
      inside && /^[[:space:]]*base_url[[:space:]]*=/ {
        base_count++
        base_value=field_value("base_url", $0)
        next
      }
      inside && /^[[:space:]]*wire_api[[:space:]]*=/ {
        wire_count++
        wire_value=field_value("wire_api", $0)
        next
      }
      inside && /^[[:space:]]*requires_openai_auth[[:space:]]*=/ {
        openai_auth_count++
        openai_auth_value=field_value("requires_openai_auth", $0)
        next
      }
      inside && /^[[:space:]]*(env_key|experimental_bearer_token)[[:space:]]*=/ {
        unmanaged_auth=1
      }
      END {
        if (main_count != 1) print "main"
        else if (other_table) print "other-table"
        else if (bad_order) print "order"
        else if (auth_table) print "auth-table"
        else if (base_count != 1 || !quoted_nonempty(base_value)) print "base-url"
        else if (wire_count != 1) print "wire-api"
        else if (wire_value != "\"responses\"" && wire_value != "\"chat\"" && wire_value != sprintf("%c", 39) "responses" sprintf("%c", 39) && wire_value != sprintf("%c", 39) "chat" sprintf("%c", 39)) print "wire-api"
        else if (openai_auth_count != 1 || openai_auth_value != "false") print "openai-auth"
        else if (unmanaged_auth) print "unmanaged-auth"
        else print "ok"
      }
    ' "$file"
  )"

  case "$result" in
    ok) return 0 ;;
    main) die "provider fragment must contain exactly one [model_providers.$provider] table" ;;
    other-table) die "provider fragment may only contain tables for 'model_providers.$provider'" ;;
    order) die "provider sub-tables must appear after [model_providers.$provider]" ;;
    auth-table) die "provider auth is managed by CCS and cannot be edited in the TOML fragment" ;;
    base-url) die "provider fragment must contain exactly one non-empty quoted base_url" ;;
    wire-api) die "provider fragment must contain exactly one wire_api set to 'responses' or 'chat'" ;;
    openai-auth) die "provider fragment must contain exactly one requires_openai_auth = false" ;;
    unmanaged-auth) die "env_key and experimental_bearer_token are managed by CCS and cannot be set in the fragment" ;;
    *) die "invalid Codex provider fragment" ;;
  esac
}

_codex_new_provider_fragment() {
  local provider="$1" output="$2"
  printf '[model_providers.%s]\nname = "%s"\nbase_url = ""\nwire_api = "responses"\nrequires_openai_auth = false\n' \
    "$provider" "$(_codex_toml_escape "$provider")" > "$output"
}

_codex_open_provider_fragment() {
  local provider="$1" file="$2"
  echo "ccs: opening Codex provider '$provider' in ${EDITOR:-vim}; the API key will be requested afterward." >&2
  if ! ${EDITOR:-vim} "$file"; then
    die "editor exited without saving Codex provider '$provider'"
  fi
}

_codex_append_managed_auth() {
  local file="$1" provider="$2" logical="${3:-$2}" command_path credential_path
  command_path="$(_codex_toml_escape "$(type -P jq)")"
  credential_path="$(_codex_toml_escape "$CODEX_AUTH_DIR/$logical.json")"
  printf '\n[model_providers.%s.auth]\ncommand = "%s"\nargs = ["-er", ".OPENAI_API_KEY | strings | select(length > 0)", "%s"]\n' \
    "$provider" "$command_path" "$credential_path" >> "$file"
}

_codex_append_fragment() {
  local file="$1" fragment="$2" tail_bytes
  if [[ -s "$file" ]]; then
    tail_bytes="$(tail -c 2 "$file" | od -An -t u1 | awk '{$1=$1; print}')"
    if [[ "$tail_bytes" == "10 10" ]]; then
      :
    elif [[ "$tail_bytes" == *" 10" || "$tail_bytes" == "10" ]]; then
      printf '\n' >> "$file"
    else
      printf '\n\n' >> "$file"
    fi
  fi
  cat "$fragment" >> "$file"
  [[ "$(tail -c 1 "$file" | wc -l | tr -d ' ')" != 0 ]] || printf '\n' >> "$file"
}

_codex_append_provider_fragment() {
  local file="$1" provider="$2" fragment="$3"
  _codex_append_fragment "$file" "$fragment"
  _codex_append_managed_auth "$file" "$provider"
}

_codex_merge_provider_fragment() {
  local provider="$1" fragment="$2" output="$3"
  _codex_config_without_provider "$provider" "$output"
  _codex_append_provider_fragment "$output" "$provider" "$fragment"
}

_codex_rename_provider_fragment() {
  local old="$1" new="$2" input="$3" output="$4"
  awk -v old="$old" -v new="$new" '
    {
      line=$0
      header=$0
      sub(/[[:space:]]*#.*/, "", header)
      gsub(/[[:space:]]/, "", header)
      if (header == "[model_providers." old "]" || index(header, "[model_providers." old ".") == 1) {
        sub("\\[model_providers\\." old, "[model_providers." new, line)
      }
      print line
    }
  ' "$input" > "$output"
}

_codex_write_openai_profile() {
  local output="$1"
  cat > "$output" <<'EOF'
[model_providers.openai]
name = "OpenAI"
base_url = "https://chatgpt.com/backend-api/codex"
wire_api = "responses"
requires_openai_auth = true
EOF
  chmod 600 "$output"
}

_codex_validate_materialized_config() {
  local file="$1" logical="$2" result
  result="$(
    awk -v logical="$logical" '
      /^[[:space:]]*model_provider[[:space:]]*=/ {
        current_count++
        if ($0 ~ /^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"ccs"[[:space:]]*$/) fixed_current++
      }
      {
        header=$0
        sub(/[[:space:]]*#.*/, "", header)
        gsub(/[[:space:]]/, "", header)
      }
      header ~ /^\[model_providers\.[A-Za-z_][A-Za-z0-9_-]*\]$/ {
        main_count++
        if (header == "[model_providers.ccs]") fixed_main++
      }
      header == "[model_providers.ccs.auth]" { auth_count++ }
      END {
        if (current_count != 1 || fixed_current != 1) print "current"
        else if (main_count != 1 || fixed_main != 1) print "main"
        else if (logical == "openai" && auth_count != 0) print "openai-auth"
        else if (logical != "openai" && auth_count != 1) print "provider-auth"
        else print "ok"
      }
    ' "$file"
  )"
  case "$result" in
    ok) return 0 ;;
    current) die "materialized Codex config must contain exactly one model_provider = \"ccs\"" ;;
    main) die "materialized Codex config must contain only [model_providers.ccs]" ;;
    openai-auth) die "materialized OpenAI provider must not contain a third-party auth table" ;;
    provider-auth) die "materialized third-party provider must contain exactly one managed auth table" ;;
    *) die "invalid materialized Codex config" ;;
  esac
}

_codex_materialize_profile() {
  local logical="$1" profile="$2" input_config="$3" output="$4"
  local auth_file="${5:-$CODEX_AUTH_DIR/$logical.json}" base fixed
  [[ -f "$profile" ]] || die "Codex logical provider '$logical' not found"
  if [[ "$logical" == "openai" ]]; then
    grep -qF '[model_providers.openai]' "$profile" \
      || die "invalid built-in OpenAI logical provider"
    grep -qE '^[[:space:]]*requires_openai_auth[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$profile" \
      || die "built-in OpenAI logical provider must require OpenAI auth"
  else
    _codex_validate_provider_fragment "$logical" "$profile"
    _codex_validate_provider_auth "$auth_file"
  fi

  base="$(mktemp "$CODEX_DIR/.ccs.materialize-base.XXXXXX")"
  fixed="$(mktemp "$CODEX_DIR/.ccs.materialize-fixed.XXXXXX")"
  _codex_register_temp "$base"
  _codex_register_temp "$fixed"
  _codex_config_file_without_all_providers "$input_config" "$base"
  _codex_config_file_with_current "$base" ccs "$output"
  _codex_rename_provider_fragment "$logical" ccs "$profile" "$fixed"
  _codex_append_fragment "$output" "$fixed"
  if [[ "$logical" != "openai" ]]; then
    _codex_append_managed_auth "$output" ccs "$logical"
  fi
  _codex_validate_materialized_config "$output" "$logical"
}

_codex_current_link_temp() {
  local logical="$1" output="$2"
  rm -f "$output"
  ln -s "$logical.toml" "$output"
}

_codex_commit_config_and_current() {
  local config_tmp="$1" logical="$2" current_tmp
  current_tmp="$(mktemp "$CODEX_PROVIDER_DIR/.ccs.current.XXXXXX")"
  _codex_register_temp "$current_tmp"
  _codex_current_link_temp "$logical" "$current_tmp"
  _codex_transaction_begin
  _codex_transaction_track "$CODEX_CONFIG"
  _codex_transaction_track "$CODEX_PROVIDER_CURRENT"
  mv "$config_tmp" "$CODEX_CONFIG"
  mv "$current_tmp" "$CODEX_PROVIDER_CURRENT"
  _codex_transaction_commit
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
    { header=$0; sub(/[[:space:]]*#.*/, "", header); gsub(/[[:space:]]/, "", header) }
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
      if _codex_config_provider_exists "$provider"; then
        display="$(_codex_config_provider_field "$provider" name)"
        base_url="$(_codex_config_provider_field "$provider" base_url)"
        wire_api="$(_codex_config_provider_field "$provider" wire_api)"
        config_tmp="$CODEX_DIR/.ccs.config.toml.tmp.$$"
        _codex_config_update_provider "$provider" "${display:-$provider}" "$base_url" "${wire_api:-responses}" "$config_tmp"
        mv "$config_tmp" "$CODEX_CONFIG"
      fi
    done
  fi

  if [[ -L "$legacy_state" ]]; then
    active="$(basename "$(readlink "$legacy_state")" .env)"
  fi
  if [[ -n "$active" && -f "$CODEX_AUTH_DIR/$active.json" ]] && _codex_config_provider_exists "$active"; then
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
    display="$(_codex_config_provider_field "$provider" name)"
    base_url="$(_codex_config_provider_field "$provider" base_url)"
    wire_api="$(_codex_config_provider_field "$provider" wire_api)"
    config_tmp="$CODEX_DIR/.ccs.config.toml.tmp.$$"
    _codex_config_update_provider \
      "$provider" "${display:-$provider}" "$base_url" "${wire_api:-responses}" "$config_tmp"
    mv "$config_tmp" "$CODEX_CONFIG"
  done < <(_codex_config_provider_names)

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

_codex_validate_fixed_migration_source() {
  local result
  result="$(
    awk '
      /^[[:space:]]*model_provider[[:space:]]*=/ {
        current_count++
        if ($0 ~ /^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"[A-Za-z_][A-Za-z0-9_-]*"[[:space:]]*$/) {
          valid_current++
        }
      }
      {
        header=$0
        sub(/[[:space:]]*#.*/, "", header)
        gsub(/[[:space:]]/, "", header)
      }
      index(header, "[model_providers.") == 1 {
        if (header !~ /^\[model_providers\.[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)*\]$/) {
          bad_header=1
        }
      }
      header ~ /^\[model_providers\.[A-Za-z_][A-Za-z0-9_-]*\]$/ {
        name=header
        sub(/^\[model_providers\./, "", name)
        sub(/\]$/, "", name)
        if (seen[name]++) duplicate=1
      }
      END {
        if (current_count > 1 || current_count != valid_current) print "current"
        else if (bad_header) print "header"
        else if (duplicate) print "duplicate"
        else print "ok"
      }
    ' "$CODEX_CONFIG"
  )"
  case "$result" in
    ok) return 0 ;;
    current) die "cannot migrate Codex config with invalid or duplicate model_provider" ;;
    header) die "cannot migrate malformed model_providers table header" ;;
    duplicate) die "cannot migrate duplicate model_providers tables" ;;
    *) die "cannot validate Codex config for fixed-provider migration" ;;
  esac
}

_codex_migrate_fixed_locked() {
  [[ -f "$CODEX_FIXED_MIGRATION_MARKER" ]] && return 0
  [[ ! -e "$CODEX_PROVIDER_DIR" && ! -L "$CODEX_PROVIDER_DIR" ]] \
    || die "cannot migrate: $CODEX_PROVIDER_DIR already exists without a completed migration marker"
  _codex_validate_fixed_migration_source

  local active provider stage profile config_tmp stamp backup_dir backup_config
  local providers=()
  active="$(_codex_config_current_raw)"
  [[ "$active" != "ccs" ]] \
    || die "cannot migrate: fixed provider ID 'ccs' is already in use without CCS metadata"
  if grep -qE '^[[:space:]]*\[model_providers\.ccs\][[:space:]]*(#.*)?$' "$CODEX_CONFIG"; then
    die "cannot migrate: logical provider 'ccs' conflicts with the fixed provider ID"
  fi
  if grep -qE '^[[:space:]]*\[model_providers\.openai\][[:space:]]*(#.*)?$' "$CODEX_CONFIG"; then
    die "cannot migrate: explicit provider table 'openai' conflicts with the built-in OpenAI profile"
  fi
  while IFS= read -r provider; do
    [[ -n "$provider" ]] && providers+=("$provider")
  done < <(sed -nE 's/^[[:space:]]*\[model_providers\.([A-Za-z_][A-Za-z0-9_-]*)\][[:space:]]*(#.*)?$/\1/p' "$CODEX_CONFIG")
  if [[ "$active" != "openai" ]]; then
    local found=0
    if [[ ${providers[0]+_} ]]; then
      for provider in "${providers[@]}"; do [[ "$provider" == "$active" ]] && found=1; done
    fi
    ((found)) || die "cannot migrate: active logical provider '$active' has no provider table"
  fi

  stage="$(mktemp -d "$CODEX_DIR/.ccs-providers.stage.XXXXXX")"
  chmod 700 "$stage"
  _codex_register_temp_dir "$stage"
  _codex_write_openai_profile "$stage/openai.toml"
  if [[ ${providers[0]+_} ]]; then
    for provider in "${providers[@]}"; do
      [[ "$provider" != "ccs" && "$provider" != "openai" ]] \
        || die "cannot migrate reserved logical provider '$provider'"
      profile="$stage/$provider.toml"
      _codex_extract_provider_fragment "$provider" "$CODEX_CONFIG" "$profile"
      if [[ "$provider" == "$active" ]]; then
        _codex_validate_provider_auth "$CODEX_AUTH_DIR/$provider.json"
        _codex_validate_provider_fragment "$provider" "$profile"
      fi
      chmod 600 "$profile"
    done
  fi
  if [[ "$active" == "openai" && -f "$CODEX_AUTH_DIR/openai.json" ]]; then
    _codex_auth_is_chatgpt "$CODEX_AUTH_DIR/openai.json" \
      || die "cannot migrate: OpenAI auth snapshot is not a ChatGPT login"
  fi
  _codex_current_link_temp "$active" "$stage/current"
  : > "$stage/.migrated-v3"
  chmod 600 "$stage/.migrated-v3"

  config_tmp="$(mktemp "$CODEX_DIR/.ccs.config.fixed.XXXXXX")"
  _codex_register_temp "$config_tmp"
  _codex_materialize_profile "$active" "$stage/$active.toml" "$CODEX_CONFIG" "$config_tmp"

  stamp="$(date +%Y%m%d%H%M%S)-$$"
  backup_dir="$CODEX_BACKUP_DIR/fixed-provider-$stamp"
  backup_config="$backup_dir/config.toml"
  mkdir -p "$backup_dir"
  chmod 700 "$CODEX_BACKUP_DIR" "$backup_dir"
  cp "$CODEX_CONFIG" "$backup_config"
  chmod 600 "$backup_config"

  _codex_transaction_begin
  _codex_transaction_track "$CODEX_CONFIG"
  _codex_transaction_track_created_dir "$CODEX_PROVIDER_DIR"
  mv "$config_tmp" "$CODEX_CONFIG"
  mv "$stage" "$CODEX_PROVIDER_DIR"
  _codex_transaction_commit
  echo "✓ ccs: migrated Codex logical providers to $CODEX_PROVIDER_DIR" >&2
  echo "  protected backup: $backup_config" >&2
}

_codex_prepare() {
  _codex_require_jq
  _codex_init_dirs
  if [[ ! -f "$CODEX_MIGRATION_MARKER" || ! -f "$CODEX_FIXED_MIGRATION_MARKER" ]]; then
    _codex_lock_acquire
    [[ -f "$CODEX_MIGRATION_MARKER" ]] || _codex_migrate_locked
    [[ -f "$CODEX_FIXED_MIGRATION_MARKER" ]] || _codex_migrate_fixed_locked
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
  local binary config_tmp current_tmp
  binary="$(type -P codex 2>/dev/null || true)"
  [[ -n "$binary" ]] || die "Codex CLI not found; install it before creating an OpenAI subscription login"

  _codex_lock_acquire
  _codex_provider_exists openai || die "built-in OpenAI logical provider is missing"
  config_tmp="$(mktemp "$CODEX_DIR/.ccs.config.login.XXXXXX")"
  current_tmp="$(mktemp "$CODEX_PROVIDER_DIR/.ccs.current.login.XXXXXX")"
  _codex_register_temp "$config_tmp"
  _codex_register_temp "$current_tmp"
  _codex_current_link_temp openai "$current_tmp"
  _codex_transaction_begin
  _codex_transaction_track "$CODEX_AUTH"
  _codex_transaction_track "$CODEX_AUTH_DIR/openai.json"
  _codex_transaction_track "$CODEX_CONFIG"
  _codex_transaction_track "$CODEX_PROVIDER_CURRENT"

  echo "ccs: starting the official Codex ChatGPT login..." >&2
  if ! "$binary" login -c 'model_provider="openai"'; then
    die "official Codex login did not complete"
  fi
  if ! jq -e '.auth_mode == "chatgpt" and (.tokens | type == "object")' "$CODEX_AUTH" >/dev/null 2>&1; then
    die "Codex login did not create a ChatGPT subscription credential; previous auth was restored"
  fi

  _codex_atomic_copy "$CODEX_AUTH" "$CODEX_AUTH_DIR/openai.json"
  _codex_materialize_profile openai "$(_codex_provider_path openai)" "$CODEX_CONFIG" "$config_tmp"
  mv "$config_tmp" "$CODEX_CONFIG"
  mv "$current_tmp" "$CODEX_PROVIDER_CURRENT"
  _codex_transaction_commit
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
  local provider="${1:-}" key fragment auth_tmp profile
  [[ -n "$provider" ]] || die "usage: ccs codex new <provider>"
  if [[ "$provider" == "openai" ]]; then
    [[ ! -f "$CODEX_AUTH_DIR/openai.json" ]] || die "OpenAI auth is already managed; run 'ccs codex login' to sign in again"
    _codex_native_login
    return 0
  fi
  [[ "$provider" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ && "$provider" != "ccs" ]] \
    || die "invalid or reserved Codex provider name '$provider'"
  _codex_provider_exists "$provider" && die "Codex provider '$provider' already exists"

  fragment="$(mktemp "$CODEX_DIR/.ccs.$provider.edit.XXXXXX")"
  chmod 600 "$fragment"
  _codex_register_temp "$fragment"
  _codex_new_provider_fragment "$provider" "$fragment"
  _codex_open_provider_fragment "$provider" "$fragment"
  _codex_validate_provider_fragment "$provider" "$fragment"
  key="$(_codex_read_secret 'API key: ')"
  [[ -n "$key" ]] || die "API key is required"

  _codex_lock_acquire
  _codex_provider_exists "$provider" && die "Codex provider '$provider' already exists"
  profile="$(_codex_provider_path "$provider")"
  [[ ! -e "$profile" && ! -L "$profile" ]] || die "Codex provider '$provider' already exists"
  [[ ! -e "$CODEX_AUTH_DIR/$provider.json" && ! -L "$CODEX_AUTH_DIR/$provider.json" ]] \
    || die "Codex auth snapshot '$provider' already exists"
  auth_tmp="$(mktemp "$CODEX_AUTH_DIR/.ccs.$provider.auth.XXXXXX")"
  _codex_register_temp "$auth_tmp"
  _codex_write_api_auth "$key" "$auth_tmp"
  _codex_transaction_begin
  _codex_transaction_track "$profile"
  _codex_transaction_track "$CODEX_AUTH_DIR/$provider.json"
  mv "$auth_tmp" "$CODEX_AUTH_DIR/$provider.json"
  mv "$fragment" "$profile"
  chmod 600 "$CODEX_AUTH_DIR/$provider.json"
  chmod 600 "$profile"
  _codex_transaction_commit
  _codex_lock_release
  echo "✓ ccs: created Codex provider '$provider'"
  echo "  switch with: ccs codex use $provider"
}

cmd_codex_use() {
  _codex_prepare
  local target="${1:-}" config_tmp profile
  [[ -n "$target" ]] || die "usage: ccs codex use <provider>"
  _codex_provider_exists "$target" || die "Codex provider '$target' not found"
  profile="$(_codex_provider_path "$target")"
  if [[ "$target" == "openai" ]]; then
    _codex_validate_auth "$CODEX_AUTH_DIR/openai.json"
    _codex_auth_is_chatgpt "$CODEX_AUTH_DIR/openai.json" \
      || die "OpenAI snapshot is not a ChatGPT login; run 'ccs codex login'"
    _codex_auth_is_chatgpt "$CODEX_AUTH" \
      || die "global ChatGPT login is unavailable; run 'ccs codex login'"
  else
    _codex_validate_provider_auth "$CODEX_AUTH_DIR/$target.json"
    _codex_validate_provider_fragment "$target" "$profile"
  fi

  _codex_lock_acquire
  _codex_provider_exists "$target" || die "Codex provider '$target' not found"
  if [[ "$target" == "openai" ]]; then
    _codex_auth_is_chatgpt "$CODEX_AUTH_DIR/openai.json" \
      || die "OpenAI snapshot is not a ChatGPT login; run 'ccs codex login'"
    _codex_auth_is_chatgpt "$CODEX_AUTH" \
      || die "global ChatGPT login is unavailable; run 'ccs codex login'"
  else
    _codex_validate_provider_auth "$CODEX_AUTH_DIR/$target.json"
    _codex_validate_provider_fragment "$target" "$profile"
  fi
  config_tmp="$(mktemp "$CODEX_DIR/.ccs.config.use.XXXXXX")"
  _codex_register_temp "$config_tmp"
  _codex_materialize_profile "$target" "$profile" "$CODEX_CONFIG" "$config_tmp"
  _codex_commit_config_and_current "$config_tmp" "$target"
  _codex_lock_release
  echo "✓ ccs: switched Codex to '$target'"
  if [[ "$target" != "openai" ]] && ! _codex_auth_is_chatgpt "$CODEX_AUTH"; then
    echo "  note: ChatGPT login is unavailable; Remote requires 'ccs codex login'"
  fi
}

cmd_codex_edit() {
  _codex_prepare
  local provider="${1:-}" new_key fragment profile baseline current_fingerprint current
  local config_tmp="" auth_tmp="" auth_source
  [[ -n "$provider" ]] || die "usage: ccs codex edit <provider>"
  [[ "$provider" != "openai" ]] || die "the built-in 'openai' provider cannot be edited"
  [[ "$provider" != "ccs" ]] || die "'ccs' is reserved for the fixed Codex provider ID"
  _codex_provider_exists "$provider" || die "Codex provider '$provider' not found"
  profile="$(_codex_provider_path "$provider")"

  fragment="$(mktemp "$CODEX_DIR/.ccs.$provider.edit.XXXXXX")"
  chmod 600 "$fragment"
  _codex_register_temp "$fragment"
  cp "$profile" "$fragment"
  baseline="$(_codex_file_fingerprint "$fragment")"
  _codex_open_provider_fragment "$provider" "$fragment"
  _codex_validate_provider_fragment "$provider" "$fragment"
  new_key="$(_codex_read_secret 'New API key (leave blank to keep current): ')"
  if [[ -z "$new_key" ]]; then
    _codex_validate_provider_auth "$CODEX_AUTH_DIR/$provider.json"
  fi

  _codex_lock_acquire
  _codex_provider_exists "$provider" || die "Codex provider '$provider' not found"
  current_fingerprint="$(_codex_file_fingerprint "$profile")"
  [[ "$current_fingerprint" == "$baseline" ]] \
    || die "Codex provider '$provider' changed while editing; no changes were written"
  if [[ -n "$new_key" ]]; then
    auth_tmp="$(mktemp "$CODEX_AUTH_DIR/.ccs.$provider.auth.XXXXXX")"
    _codex_register_temp "$auth_tmp"
    _codex_write_api_auth "$new_key" "$auth_tmp"
    auth_source="$auth_tmp"
  else
    auth_source="$CODEX_AUTH_DIR/$provider.json"
  fi
  _codex_validate_provider_auth "$auth_source"
  current="$(_codex_current_raw)"
  if [[ "$current" == "$provider" ]]; then
    config_tmp="$(mktemp "$CODEX_DIR/.ccs.config.edit.XXXXXX")"
    _codex_register_temp "$config_tmp"
    _codex_materialize_profile "$provider" "$fragment" "$CODEX_CONFIG" "$config_tmp" "$auth_source"
  fi

  _codex_transaction_begin
  _codex_transaction_track "$profile"
  [[ -z "$auth_tmp" ]] || _codex_transaction_track "$CODEX_AUTH_DIR/$provider.json"
  [[ -z "$config_tmp" ]] || _codex_transaction_track "$CODEX_CONFIG"
  mv "$fragment" "$profile"
  [[ -z "$auth_tmp" ]] || mv "$auth_tmp" "$CODEX_AUTH_DIR/$provider.json"
  [[ -z "$config_tmp" ]] || mv "$config_tmp" "$CODEX_CONFIG"
  chmod 600 "$profile" "$CODEX_AUTH_DIR/$provider.json"
  _codex_transaction_commit
  _codex_lock_release
  echo "✓ ccs: updated Codex provider '$provider'"
}

cmd_codex_rename() {
  _codex_prepare
  local old="${1:-}" new="${2:-}" current old_profile new_profile renamed_fragment auth_tmp
  local config_tmp="" current_tmp=""
  [[ $# -eq 2 && -n "$old" && -n "$new" ]] || die "usage: ccs codex rename <old> <new>"
  [[ "$old" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "invalid Codex provider name '$old'"
  [[ "$new" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "invalid Codex provider name '$new'"
  [[ "$old" != "openai" ]] || die "the built-in 'openai' provider cannot be renamed"
  [[ "$new" != "openai" ]] || die "'openai' is reserved for the built-in provider"
  [[ "$old" != "ccs" && "$new" != "ccs" ]] || die "'ccs' is reserved for the fixed Codex provider ID"
  [[ "$old" != "$new" ]] || die "the new provider name must be different"
  _codex_provider_exists "$old" || die "Codex provider '$old' not found"
  ! _codex_provider_exists "$new" || die "Codex provider '$new' already exists"
  [[ ! -e "$CODEX_AUTH_DIR/$new.json" && ! -L "$CODEX_AUTH_DIR/$new.json" ]] \
    || die "Codex auth snapshot '$new' already exists"
  _codex_validate_provider_auth "$CODEX_AUTH_DIR/$old.json"

  _codex_lock_acquire
  _codex_provider_exists "$old" || die "Codex provider '$old' not found"
  ! _codex_provider_exists "$new" || die "Codex provider '$new' already exists"
  [[ ! -e "$CODEX_AUTH_DIR/$new.json" && ! -L "$CODEX_AUTH_DIR/$new.json" ]] \
    || die "Codex auth snapshot '$new' already exists"
  _codex_validate_provider_auth "$CODEX_AUTH_DIR/$old.json"
  current="$(_codex_current_raw)"
  old_profile="$(_codex_provider_path "$old")"
  new_profile="$(_codex_provider_path "$new")"
  renamed_fragment="$(mktemp "$CODEX_DIR/.ccs.$new.rename-target.XXXXXX")"
  auth_tmp="$(mktemp "$CODEX_AUTH_DIR/.ccs.$new.auth.XXXXXX")"
  chmod 600 "$renamed_fragment" "$auth_tmp"
  _codex_register_temp "$renamed_fragment"
  _codex_register_temp "$auth_tmp"
  _codex_rename_provider_fragment "$old" "$new" "$old_profile" "$renamed_fragment"
  _codex_validate_provider_fragment "$new" "$renamed_fragment"
  cp "$CODEX_AUTH_DIR/$old.json" "$auth_tmp"
  _codex_validate_provider_auth "$auth_tmp"

  if [[ "$current" == "$old" ]]; then
    config_tmp="$(mktemp "$CODEX_DIR/.ccs.config.rename.XXXXXX")"
    current_tmp="$(mktemp "$CODEX_PROVIDER_DIR/.ccs.current.rename.XXXXXX")"
    _codex_register_temp "$config_tmp"
    _codex_register_temp "$current_tmp"
    _codex_materialize_profile "$new" "$renamed_fragment" "$CODEX_CONFIG" "$config_tmp" "$auth_tmp"
    _codex_current_link_temp "$new" "$current_tmp"
  fi

  _codex_transaction_begin
  _codex_transaction_track "$old_profile"
  _codex_transaction_track "$new_profile"
  _codex_transaction_track "$CODEX_AUTH_DIR/$old.json"
  _codex_transaction_track "$CODEX_AUTH_DIR/$new.json"
  [[ -z "$config_tmp" ]] || _codex_transaction_track "$CODEX_CONFIG"
  [[ -z "$current_tmp" ]] || _codex_transaction_track "$CODEX_PROVIDER_CURRENT"
  mv "$renamed_fragment" "$new_profile"
  mv "$auth_tmp" "$CODEX_AUTH_DIR/$new.json"
  [[ -z "$config_tmp" ]] || mv "$config_tmp" "$CODEX_CONFIG"
  [[ -z "$current_tmp" ]] || mv "$current_tmp" "$CODEX_PROVIDER_CURRENT"
  rm -f "$old_profile" "$CODEX_AUTH_DIR/$old.json"
  chmod 600 "$new_profile" "$CODEX_AUTH_DIR/$new.json"
  _codex_transaction_commit
  _codex_lock_release
  echo "✓ ccs: renamed Codex provider '$old' to '$new'"
}

cmd_codex_rm() {
  _codex_prepare
  local provider="${1:-}" answer profile
  [[ -n "$provider" ]] || die "usage: ccs codex rm <provider>"
  [[ "$provider" != "openai" ]] || die "the built-in 'openai' provider cannot be removed"
  _codex_provider_exists "$provider" || die "Codex provider '$provider' not found"
  [[ "$provider" != "$(_codex_current_raw)" ]] || die "cannot remove active provider '$provider'; switch first"
  read -r -p "Remove Codex provider '$provider'? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Cancelled."; return 0; }
  _codex_lock_acquire
  _codex_provider_exists "$provider" || die "Codex provider '$provider' not found"
  [[ "$provider" != "$(_codex_current_raw)" ]] || die "cannot remove active provider '$provider'; switch first"
  profile="$(_codex_provider_path "$provider")"
  _codex_transaction_begin
  _codex_transaction_track "$profile"
  _codex_transaction_track "$CODEX_AUTH_DIR/$provider.json"
  rm -f "$profile" "$CODEX_AUTH_DIR/$provider.json"
  _codex_transaction_commit
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
  ccs codex new <provider>    Create a provider in \$EDITOR, then enter its API key
  ccs codex new openai        Create an official ChatGPT subscription login
  ccs codex login             Sign in to OpenAI again and refresh its snapshot
  ccs codex edit <name>       Edit provider TOML in \$EDITOR, then optionally rotate its API key
  ccs codex rename <old> <new> Rename a provider and its saved auth
  ccs codex rm <name>         Remove an inactive provider
  ccs codex show [<name>]     Show provider metadata (secrets masked)

Files:
  Fixed config:     $CODEX_CONFIG
  Logical profiles: $CODEX_PROVIDER_DIR
  Logical current:  $CODEX_PROVIDER_CURRENT
  ChatGPT auth:     $CODEX_AUTH
  Auth store:       $CODEX_AUTH_DIR
EOF
}

cmd_codex() {
  local sub="${1:-help}"; shift 2>/dev/null || true
  case "$sub" in
    list|ls) cmd_codex_list ;; current|c) cmd_codex_current ;;
    use|sw|switch) cmd_codex_use "$@" ;; new|create) cmd_codex_new "$@" ;;
    login) cmd_codex_login ;;
    edit|e) cmd_codex_edit "$@" ;; rename|ren) cmd_codex_rename "$@" ;;
    rm|remove) cmd_codex_rm "$@" ;;
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
  exec bash -c 'curl -fsSL "$1/install.sh" | bash' _ "$REPO"
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
  ccs rename <old> <new> Rename a profile and its statusline binding
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
  rename|ren)           cmd_rename "$@" ;;
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
