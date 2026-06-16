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
ccs path              Print profiles directory
ccs version           Print version
```

Short aliases: `ls`, `c`, `sw`, `e`, `rm`, `source`, `src`, `off`.

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
