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
ccs codex new proxy   Create a provider in $EDITOR, then enter its API key
ccs codex new openai  Create an official ChatGPT subscription login
ccs codex login       Sign in to OpenAI again and refresh its snapshot
ccs codex use proxy   Switch providers while keeping ChatGPT signed in
ccs codex edit proxy  Edit provider TOML, then optionally rotate its API key
ccs codex list        List providers and saved credentials
ccs codex show proxy  Show provider metadata with secrets masked
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

## Codex providers

Codex provider switching does not use shell environment variables. `ccs codex
new <provider>` opens a temporary TOML fragment in `${EDITOR:-vim}` with the
provider name, an empty `base_url`, `wire_api = "responses"`, and
`requires_openai_auth = false`. After the editor exits, CCS validates the
fragment and prompts for the API key separately with hidden terminal input.
Only then does it atomically merge the provider into `~/.codex/config.toml`
and store the key in a protected snapshot under `~/.codex/ccs-auth/`.

`ccs codex edit <provider>` opens only that provider's TOML tables, not the
complete Codex config. Other providers and top-level settings are preserved.
After editing, enter a new API key to rotate it or leave the prompt blank to
keep the saved key. Provider names cannot be changed in the editor; remove and
recreate a provider to rename it. The command-backed `.auth` table is managed
by CCS and is regenerated after every successful edit.

`ccs codex use <provider>` updates only the top-level `model_provider`.
`~/.codex/auth.json` remains the official ChatGPT login so Codex Remote can
continue authenticating the desktop host. Model requests use the selected
provider's independent key through Codex's command-backed bearer-token support.
Third-party providers default to `requires_openai_auth = false`, so ChatGPT
OAuth tokens are never sent to their endpoints.

For a new machine, create the official subscription credential through Codex's
native browser login. CCS never handles the password or OAuth exchange itself;
after Codex finishes, CCS validates `auth.json` and stores the complete login:

```bash
ccs codex new openai
```

Use `ccs codex login` later to sign in again or refresh the managed OpenAI
credential.

```bash
ccs codex new proxy
ccs codex use proxy
ccs codex current
ccs codex show proxy
ccs codex use openai
```

On the first v0.4 command, v0.3 providers are converted to independent command
auth and the saved ChatGPT login is restored as global Codex auth. Older Codex
`.env` profiles are also migrated automatically, with the old profile directory
retained as a timestamped read-only backup.

Codex files:

| Path | Purpose |
|------|---------|
| `~/.codex/config.toml` | Provider definitions and active `model_provider` |
| `~/.codex/auth.json` | Official ChatGPT login used by Codex and Remote |
| `~/.codex/ccs-auth/openai.json` | Protected backup of the complete ChatGPT login |
| `~/.codex/ccs-auth/<provider>.json` | Protected third-party key read through command auth |
