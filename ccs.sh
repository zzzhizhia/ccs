#!/bin/bash
# ccs — Claude Code Switch
# https://github.com/zzzhizhia/ccs
# Standalone script. The thin shell wrapper in .zshenv evals stdout for
# use/env/source/unset so they affect the calling shell; everything else runs
# directly via `command ccs.sh`.

set -euo pipefail

VERSION="0.1.1"
REPO="https://raw.githubusercontent.com/zzzhizhia/ccs/main"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CCS_DIR="${CCS_DIR:-$XDG_CONFIG_HOME/ccs/profiles}"
CCS_STATE="${CCS_STATE:-$XDG_STATE_HOME/ccs}"
CURRENT="$CCS_STATE/current"
CCS_CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CCS_STATUSLINE_SCRIPT="$XDG_CONFIG_HOME/ccs/statusline.sh"

mkdir -p "$CCS_DIR" "$CCS_STATE"

# Single source of truth for all Claude Code env vars managed by ccs.
CCS_VARS=(
  ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL
  ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
  CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL
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
      echo "export $v=\"\""
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
  ccs help              This message

Profiles: $CCS_DIR
State:    $CURRENT
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
  help|-h|--help)       cmd_help ;;
  *)                    echo "ccs: unknown command '$cmd' — run \`ccs help\` for usage" >&2; exit 1 ;;
esac
