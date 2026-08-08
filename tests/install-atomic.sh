#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_HOME="$(mktemp -d)"
TEST_CONFIG="$TEST_HOME/.config"
INSTALLED="$TEST_CONFIG/ccs/ccs.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

mkdir -p "$(dirname "$INSTALLED")"
printf '#!/bin/bash\necho old\n' > "$INSTALLED"
chmod 711 "$INSTALLED"
old_inode="$(stat -f '%i' "$INSTALLED")"

HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_CONFIG" SHELL=/bin/zsh \
  bash "$ROOT/install.sh" >/dev/null

new_inode="$(stat -f '%i' "$INSTALLED")"
[[ "$new_inode" != "$old_inode" ]] || fail "installer overwrote ccs.sh in place"
cmp -s "$ROOT/ccs.sh" "$INSTALLED" || fail "installed ccs.sh differs from source"
assert_eq "$(stat -f '%Lp' "$INSTALLED")" "755"
assert_eq "$(HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_CONFIG" "$INSTALLED" version)" "ccs 0.6.3"
grep -qF "source \"\${XDG_CONFIG_HOME:-\$HOME/.config}/ccs/init.sh\"" "$TEST_HOME/.zshenv" \
  || fail "zsh hook was not installed"

echo "PASS: atomic installer replacement"
