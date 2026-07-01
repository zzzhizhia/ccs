# ccs — Claude Code Switch

Quickly switch between Claude Code API profiles (different API keys, base URLs, models).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/zzzhizhia/ccs/main/install.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/zzzhizhia/ccs.git && cd ccs && ./install.sh
```

Done. Open a new terminal, or `exec $SHELL`.

Supports **zsh**, **bash**, and **fish** — detected automatically.

## Usage

```
ccs new work          Create a profile, opens $EDITOR
ccs edit work         Edit an existing profile
ccs list              List all profiles (* = active)
ccs use deepseek      Switch profile (current terminal + persist)
ccs env minimax       Source a profile in current terminal only
ccs show              Show active profile (keys masked)
ccs unset             Clear all Claude Code env vars
ccs statusline        List profiles with bound statuslines
ccs statusline bind deepseek   Bind a statusline to a profile
ccs statusline unbind deepseek Remove a statusline binding
ccs statusline show deepseek   Show a profile's statusline
ccs path              Print profiles directory
ccs version           Print version
```

Short aliases: `ls`, `c`, `sw`, `e`, `rm`, `source`, `src`, `off`.

## Statusline

Each profile can have its own **statusline** — a custom script displayed at the bottom
of the Claude Code interface. When you switch profiles with `ccs use` or `ccs env`,
the statusline updates automatically.

```bash
# Bind a statusline to a profile (opens $EDITOR with a template)
ccs statusline bind deepseek

# Or bind with an inline command
ccs statusline bind openrouter --command 'printf "\\033[1;32mOR\\033[0m"'

# The statusline reads Claude Code session JSON on stdin
# Example template: shows profile name + model
```

When `ccs use <profile>` runs and the profile has a `.statusline` file, ccs:
1. Writes the fixed statusLine config to `~/.claude/settings.json` (first time only)
2. Copies `<profile>.statusline` → `~/.config/ccs/statusline.sh`

The statusline script receives session JSON from Claude Code via stdin, including
`model.display_name`, `workspace.current_dir`, etc.

## Profile format

Profiles live at `$CCS_DIR` (default `~/.config/ccs/profiles/`). Each is a shell-sourcable
`.env` file:

```bash
export ANTHROPIC_AUTH_TOKEN="sk-..."
export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
export ANTHROPIC_MODEL="deepseek-v4-pro[1m]"
```

## How it works

`ccs.sh` is a standalone script on `PATH`. A thin shell wrapper in your rc file
catches `use`/`env`/`unset` and `eval`s their output so the current shell picks
up the change — a child process cannot modify its parent's environment.

New terminals auto-restore the last `ccs use` profile via a symlink at
`$CCS_STATE/current`.

## Paths

| Variable | Default | Purpose |
|----------|---------|---------|
| `XDG_CONFIG_HOME` | `~/.config` | Profiles live under `$XDG_CONFIG_HOME/ccs/` |
| `XDG_STATE_HOME` | `~/.local/state` | Active profile symlink at `$XDG_STATE_HOME/ccs/current` |
