# >>> ccs >>>
_CCS_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/ccs"
export PATH="$_CCS_HOME:$PATH"
ccs() {
  case "${1:-}" in
    use|sw|switch|env|source|src|unset|off)
      eval "$(command ccs.sh "$@")" ;;
    *) command ccs.sh "$@" ;;
  esac
}
CCS_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ccs"

_ccs_sync_statusline() {
  local sl_src="$1"
  local sl_dst="$2"
  local profile_name="$3"
  local tmp

  # Build beside the destination so the replacement stays atomic. Any
  # filesystem or permission failure is intentionally ignored during shell
  # startup; the active profile environment must still be restored.
  tmp="$(mktemp "${sl_dst}.tmp.XXXXXX" 2>/dev/null)" || return 0
  if ! {
    printf '#!/bin/bash\n'
    printf '# ccs statusline for %s\n' "$profile_name"
    cat "$sl_src"
  } > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || :
    return 0
  fi

  if cmp -s "$tmp" "$sl_dst" 2>/dev/null && [ -x "$sl_dst" ]; then
    rm -f "$tmp" 2>/dev/null || :
    return 0
  fi

  if ! chmod 755 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$sl_dst" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || :
  fi
  return 0
}

if [ -f "$CCS_STATE/current" ]; then
  source "$CCS_STATE/current"
  CCS_DIR="${CCS_DIR:-$_CCS_HOME/profiles}"
  if [ -L "$CCS_STATE/current" ]; then
    profile_name="$(basename "$(readlink "$CCS_STATE/current")" .env)"
    sl_src="$CCS_DIR/$profile_name.statusline"
    sl_dst="$_CCS_HOME/statusline.sh"
    if [ -f "$sl_src" ]; then
      _ccs_sync_statusline "$sl_src" "$sl_dst" "$profile_name"
    fi
  fi
fi
# <<< ccs <<<
