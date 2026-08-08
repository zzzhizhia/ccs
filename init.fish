# >>> ccs >>>
set -gx _CCS_HOME (test -n "$XDG_CONFIG_HOME"; and echo "$XDG_CONFIG_HOME"; or echo "$HOME/.config")/ccs
fish_add_path "$_CCS_HOME"
function ccs
  switch "$argv[1]"
    case use sw switch env source src unset off
      eval (env CCS_SHELL=fish command ccs.sh $argv)
    case '*'
      command ccs.sh $argv
  end
end
set -gx CCS_STATE (test -n "$XDG_STATE_HOME"; and echo "$XDG_STATE_HOME"; or echo "$HOME/.local/state")/ccs

function _ccs_sync_statusline
  set -l sl_src $argv[1]
  set -l sl_dst $argv[2]
  set -l profile_name $argv[3]
  set -l tmp (mktemp "$sl_dst.tmp.XXXXXX" 2>/dev/null)

  # Build beside the destination so the replacement stays atomic. Any
  # filesystem or permission failure is intentionally ignored during shell
  # startup; the active profile environment must still be restored.
  if test -z "$tmp"
    return 0
  end

  printf "#!/bin/bash\n# ccs statusline for %s\n" "$profile_name" > "$tmp" 2>/dev/null
  or begin
    rm -f "$tmp" 2>/dev/null
    return 0
  end
  cat "$sl_src" >> "$tmp" 2>/dev/null
  or begin
    rm -f "$tmp" 2>/dev/null
    return 0
  end

  if cmp -s "$tmp" "$sl_dst" 2>/dev/null
    if test -x "$sl_dst"
      rm -f "$tmp" 2>/dev/null
      return 0
    end
  end

  chmod 755 "$tmp" 2>/dev/null
  or begin
    rm -f "$tmp" 2>/dev/null
    return 0
  end
  mv -f "$tmp" "$sl_dst" 2>/dev/null
  or rm -f "$tmp" 2>/dev/null
  return 0
end

if test -f "$CCS_STATE/current"
  source "$CCS_STATE/current"
  set -gx CCS_DIR (test -n "$CCS_DIR"; and echo "$CCS_DIR"; or echo "$_CCS_HOME/profiles")
  if test -L "$CCS_STATE/current"
    set profile_name (basename (readlink "$CCS_STATE/current") .env)
    set sl_src "$CCS_DIR/$profile_name.statusline"
    set sl_dst "$_CCS_HOME/statusline.sh"
    if test -f "$sl_src"
      _ccs_sync_statusline "$sl_src" "$sl_dst" "$profile_name"
    end
  end
end
# <<< ccs <<<
