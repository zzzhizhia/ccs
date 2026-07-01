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
if [ -f "$CCS_STATE/current" ]; then
  source "$CCS_STATE/current"
  CCS_DIR="${CCS_DIR:-$_CCS_HOME/profiles}"
  if [ -L "$CCS_STATE/current" ]; then
    profile_name="$(basename "$(readlink "$CCS_STATE/current")" .env)"
    sl_src="$CCS_DIR/$profile_name.statusline"
    sl_dst="$_CCS_HOME/statusline.sh"
    if [ -f "$sl_src" ]; then
      { printf '#!/bin/bash\n'; printf '# ccs statusline for %s\n' "$profile_name"; cat "$sl_src"; } > "$sl_dst"
      chmod +x "$sl_dst"
    fi
  fi
fi
# <<< ccs <<<
