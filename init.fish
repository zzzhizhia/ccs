# >>> ccs >>>
set -gx _CCS_HOME (test -n "$XDG_CONFIG_HOME"; and echo "$XDG_CONFIG_HOME"; or echo "$HOME/.config")/ccs
fish_add_path "$_CCS_HOME"
function ccs
  switch "$argv[1]"
    case use sw switch env source src unset off
      eval (command ccs.sh $argv)
    case codex
      switch "$argv[2]"
        case use sw switch env source src unset off
          eval (command ccs.sh $argv)
        case '*'
          command ccs.sh $argv
      end
    case '*'
      command ccs.sh $argv
  end
end
function codex
  set -l provider "$CCS_CODEX_PROVIDER"
  set -l explicit 0
  set -l next_config 0
  for arg in $argv
    if test $next_config -eq 1
      string match -q 'model_provider=*' -- $arg; and set explicit 1
      set next_config 0
      continue
    end
    switch $arg
      case -p --profile '--profile=*'
        set explicit 1
      case -c --config
        set next_config 1
      case '--config=model_provider=*' 'model_provider=*' 'model_provider =*'
        set explicit 1
    end
  end
  if test -n "$provider"; and test $explicit -eq 0
    command codex -c "model_provider=\"$provider\"" $argv
  else
    command codex $argv
  end
end
set -gx CCS_STATE (test -n "$XDG_STATE_HOME"; and echo "$XDG_STATE_HOME"; or echo "$HOME/.local/state")/ccs
if test -f "$CCS_STATE/current"
  source "$CCS_STATE/current"
  set -gx CCS_DIR (test -n "$CCS_DIR"; and echo "$CCS_DIR"; or echo "$_CCS_HOME/profiles")
  if test -L "$CCS_STATE/current"
    set profile_name (basename (readlink "$CCS_STATE/current") .env)
    set sl_src "$CCS_DIR/$profile_name.statusline"
    set sl_dst "$_CCS_HOME/statusline.sh"
    if test -f "$sl_src"
      printf "#!/bin/bash\n# ccs statusline for %s\n" "$profile_name" > "$sl_dst"
      cat "$sl_src" >> "$sl_dst"
      chmod +x "$sl_dst"
    end
  end
end
set -l CCS_CODEX_STATE (test -n "$XDG_STATE_HOME"; and echo "$XDG_STATE_HOME"; or echo "$HOME/.local/state")/ccs/codex
if test -L "$CCS_CODEX_STATE/current"
  source "$CCS_CODEX_STATE/current"
end
# <<< ccs <<<
