#!/bin/bash
# ccs — Claude Code Switch
# https://github.com/zzzhizhia/ccs
# Standalone script. The thin shell wrapper in .zshenv evals stdout for
# use/source/unset so they affect the calling shell; everything else runs
# directly via `command ccs.sh`.

set -euo pipefail

VERSION="0.1.0"
REPO="https://raw.githubusercontent.com/zzzhizhia/ccs/main"

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CCS_DIR="${CCS_DIR:-$XDG_CONFIG_HOME/ccs/profiles}"
CCS_STATE="${CCS_STATE:-$XDG_STATE_HOME/ccs}"
CURRENT="$CCS_STATE/current"

mkdir -p "$CCS_DIR" "$CCS_STATE"

# Single source of truth for all Claude Code env vars managed by ccs.
CCS_VARS=(
  ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL
  ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
  CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_EFFORT_LEVEL
)

die() { echo "ccs: $*" >&2; exit 1; }

# ── commands that output shell code (eval'd by wrapper) ──────────────

cmd_use() {
  local name="${1:-}"; [[ -z "$name" ]] && die "usage: ccs use <profile>"
  local profile="$CCS_DIR/$name.env"
  [[ -f "$profile" ]] || die "profile '$name' not found"
  ln -sf "$profile" "$CURRENT"
  echo "source $CURRENT"
  echo "✓ ccs: switched to '$name'" >&2
  cmd_show "$name" >&2
}

cmd_source() {
  local name="${1:-}"; [[ -z "$name" ]] && die "usage: ccs source <profile>"
  local profile="$CCS_DIR/$name.env"
  [[ -f "$profile" ]] || die "profile '$name' not found"
  echo "source $profile"
  echo "✓ ccs: sourced '$name' (current terminal only)" >&2
  cmd_show "$name" >&2
}

cmd_unset() {
  echo "unset ${CCS_VARS[*]}"
  rm -f "$CURRENT"
  echo "✓ ccs: cleared Claude Code env" >&2
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
  local stamp="$CCS_STATE/install.sha256"
  if [[ "${1:-}" == "--version" ]]; then
    local remote remote_sha
    remote=$(curl -fsSL "$REPO/install.sh") || die "failed to check latest version"
    remote_sha=$(echo "$remote" | shasum -a 256 | cut -d' ' -f1)
    if [[ -f "$stamp" ]] && [[ "$(cat "$stamp")" == "$remote_sha" ]]; then
      echo "ccs is up to date"
    else
      echo "update available — run: ccs update"
    fi
    return
  fi
  curl -fsSL "$REPO/install.sh" | bash
  curl -fsSL "$REPO/install.sh" | shasum -a 256 | cut -d' ' -f1 > "$stamp"
}

cmd_help() {
  cat <<EOF
ccs — Claude Code Switch

Usage:
  ccs list              List profiles (current one highlighted)
  ccs current           Show active profile name
  ccs use <name>        Switch to profile (current terminal + persist)
  ccs source <name>     Source profile in current terminal only
  ccs new <name>        Create a new profile (opens \$EDITOR)
  ccs edit <name>       Edit an existing profile
  ccs rm <name>         Remove a profile
  ccs show [<name>]     Show a profile's env file (sensitive keys masked)
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

# ── dispatch ─────────────────────────────────────────────────────────

cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
  list|ls)              cmd_list ;;
  current|c)            cmd_current ;;
  use|sw|switch)        cmd_use "$@" ;;
  source|src)           cmd_source "$@" ;;
  new|create)           cmd_new "$@" ;;
  edit|e)               cmd_edit "$@" ;;
  rm|remove)            cmd_rm "$@" ;;
  unset|off)            cmd_unset ;;
  show)                 cmd_show "$@" ;;
  path)                 echo "$CCS_DIR" ;;
  update)               cmd_update "$@" ;;
  version|-V|--version) echo "ccs $VERSION" ;;
  help|-h|--help)       cmd_help ;;
  *)                    echo "ccs: unknown command '$cmd' — run \`ccs help\` for usage" >&2; exit 1 ;;
esac
