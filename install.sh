#!/usr/bin/env bash
# install.sh — install ccs for zsh / bash / fish.
# https://github.com/zzzhizhia/ccs
# Safe to run repeatedly (idempotent).
# curl -fsSL https://raw.githubusercontent.com/zzzhizhia/ccs/main/install.sh | bash
set -euo pipefail

REPO="https://raw.githubusercontent.com/zzzhizhia/ccs/main"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"

# Source files: prefer local copies, fall back to remote download.
SRC="${SCRIPT_DIR:+$SCRIPT_DIR/ccs.sh}"
INIT_SRC="${SCRIPT_DIR:+$SCRIPT_DIR/init.sh}"
INIT_FISH_SRC="${SCRIPT_DIR:+$SCRIPT_DIR/init.fish}"

if [[ -z "$SRC" || ! -f "$SRC" ]]; then
  SRC="$(mktemp)"
  curl -fsSL "$REPO/ccs.sh" -o "$SRC"
  trap 'rm -f "$SRC"' EXIT
fi
if [[ -z "$INIT_SRC" || ! -f "$INIT_SRC" ]]; then
  INIT_SRC="$(mktemp)"
  curl -fsSL "$REPO/init.sh" -o "$INIT_SRC"
  trap 'rm -f "$INIT_SRC"' EXIT
fi
if [[ -z "$INIT_FISH_SRC" || ! -f "$INIT_FISH_SRC" ]]; then
  INIT_FISH_SRC="$(mktemp)"
  curl -fsSL "$REPO/init.fish" -o "$INIT_FISH_SRC"
  trap 'rm -f "$INIT_FISH_SRC"' EXIT
fi

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DST="$XDG_CONFIG_HOME/ccs/ccs.sh"
INIT="$XDG_CONFIG_HOME/ccs/init.sh"
INIT_FISH="$XDG_CONFIG_HOME/ccs/init.fish"

hook_zsh() { cat <<'EOF'
# >>> ccs >>>
source "${XDG_CONFIG_HOME:-$HOME/.config}/ccs/init.sh"
# <<< ccs <<<
EOF
}

hook_bash() { cat <<'EOF'
# >>> ccs >>>
source "${XDG_CONFIG_HOME:-$HOME/.config}/ccs/init.sh"
# <<< ccs <<<
EOF
}

hook_fish() { cat <<'EOF'
# >>> ccs >>>
if test -f "$XDG_CONFIG_HOME/ccs/init.fish"
  source "$XDG_CONFIG_HOME/ccs/init.fish"
else
  source "$HOME/.config/ccs/init.fish"
end
# <<< ccs <<<
EOF
}

# ── Helpers ──

install_hook() {
  local rc="$1" hook="$2"

  _append_hook() {
    if [[ -s "$rc" ]]; then
      local last2
      last2="$(tail -c 2 "$rc" | od -An -tx1 | tr -d ' ')"
      if [[ "$last2" == "0a0a" ]]; then
        printf '%s\n' "$hook" >> "$rc"
      else
        printf '\n%s\n' "$hook" >> "$rc"
      fi
    else
      printf '%s\n' "$hook" > "$rc"
    fi
  }

  if [[ -f "$rc" ]]; then
    if grep -qF '# >>> ccs >>>' "$rc" 2>/dev/null; then
      sed -i '' '/^# >>> ccs >>>$/,/^# <<< ccs <<<$/d' "$rc"
      _append_hook
      echo "✓ updated ccs hook in $rc"
    else
      _append_hook
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

cp "$INIT_SRC" "$INIT"
echo "✓ init.sh → $INIT"

cp "$INIT_FISH_SRC" "$INIT_FISH"
echo "✓ init.fish → $INIT_FISH"

sh="$(detect_shell)"
case "$sh" in
  zsh)  rc="$HOME/.zshenv";               install_hook "$rc" "$(hook_zsh)"  ;;
  bash) rc="$HOME/.bashrc";                install_hook "$rc" "$(hook_bash)" ;;
  fish) rc="$HOME/.config/fish/config.fish"; install_hook "$rc" "$(hook_fish)" ;;
esac

echo
if [[ -t 0 ]]; then
  echo "ccs installed for $sh. Restarting shell..."
  exec "$SHELL" -l
else
  echo "ccs installed for $sh."
  echo "Activate now:  exec \$SHELL"
fi
