#!/usr/bin/env bash
# install.sh — install ccs for zsh / bash / fish.
# Safe to run repeatedly (idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/ccs.sh"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DST="$XDG_CONFIG_HOME/ccs/ccs.sh"

# ── Hook content (all $vars are literal —  resolved by the user's shell) ──

hook_zsh() { cat <<'EOF'
# >>> ccs >>>
export PATH="$HOME/.config/ccs:$PATH"
ccs() {
  case "${1:-}" in
    use|sw|switch|source|src|unset|off)
      eval "$(command ccs.sh "$@")" ;;
    *) command ccs.sh "$@" ;;
  esac
}
CCS_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ccs"
[ -f "$CCS_STATE/current" ] && source "$CCS_STATE/current"
# <<< ccs <<<
EOF
}

hook_bash() { cat <<'EOF'
# >>> ccs >>>
export PATH="$HOME/.config/ccs:$PATH"
ccs() {
  case "${1:-}" in
    use|sw|switch|source|src|unset|off)
      eval "$(command ccs.sh "$@")" ;;
    *) command ccs.sh "$@" ;;
  esac
}
CCS_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ccs"
[ -f "$CCS_STATE/current" ] && source "$CCS_STATE/current"
# <<< ccs <<<
EOF
}

hook_fish() { cat <<'EOF'
# >>> ccs >>>
fish_add_path "$HOME/.config/ccs"
function ccs
  switch "$argv[1]"
    case use sw switch source src unset off
      eval (command ccs.sh $argv)
    case '*'
      command ccs.sh $argv
  end
end
set -gx CCS_STATE (test -n "$XDG_STATE_HOME"; and echo "$XDG_STATE_HOME"; or echo "$HOME/.local/state")/ccs
test -f "$CCS_STATE/current"; and source "$CCS_STATE/current"
# <<< ccs <<<
EOF
}

# ── Helpers ──

install_hook() {
  local rc="$1" hook="$2"
  if [[ -f "$rc" ]]; then
    if grep -qF '# >>> ccs >>>' "$rc" 2>/dev/null; then
      sed -i '' '/^# >>> ccs >>>$/,/^# <<< ccs <<<$/d' "$rc"
      printf '\n%s\n' "$hook" >> "$rc"
      echo "✓ updated ccs hook in $rc"
    else
      printf '\n%s\n' "$hook" >> "$rc"
      echo "✓ added ccs hook to $rc"
    fi
  else
    mkdir -p "$(dirname "$rc")"
    printf '%s\n' "$hook" > "$rc"
    echo "✓ created $rc with ccs hook"
  fi
}

detect_shell() {
  case "$(basename "${SHELL:-}")" in
    zsh)  echo "zsh"  ;;
    bash) echo "bash" ;;
    fish) echo "fish" ;;
    *)    echo "zsh"  ;;
  esac
}

# ── Install ──

mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"
chmod +x "$DST"
echo "✓ ccs.sh → $DST"

sh="$(detect_shell)"
case "$sh" in
  zsh)  install_hook "$HOME/.zshenv"               "$(hook_zsh)"  ;;
  bash) install_hook "$HOME/.bashrc"                "$(hook_bash)" ;;
  fish) install_hook "$HOME/.config/fish/config.fish" "$(hook_fish)" ;;
esac

# Apply to current shell
export PATH="$HOME/.config/ccs:$PATH"
CCS_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ccs"
[[ -f "$CCS_STATE/current" ]] && source "$CCS_STATE/current" 2>/dev/null || true

echo
echo "ccs installed for $sh."
