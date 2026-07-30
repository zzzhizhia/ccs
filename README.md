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
ccs rename work team  Rename a profile and its statusline binding
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
ccs codex rename proxy gateway  Rename a provider and its saved auth
ccs codex list        List providers and saved credentials
ccs codex show proxy  Show provider metadata with secrets masked
```

Short aliases: `ls`, `c`, `sw`, `e`, `ren`, `rm`, `source`, `src`, `off`.

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

Codex provider switching does not use shell environment variables. The names
used by `ccs codex` (`openai`, `proxy`, and so on) are **logical provider
profiles**. Codex itself always sees the fixed ID `ccs`: `config.toml` contains
exactly one `model_provider = "ccs"` line and one `[model_providers.ccs]` main
table. Switching profiles replaces that fixed table and its nested tables, so
Codex App conversation visibility does not change with the upstream service.

`ccs codex new <provider>` opens a temporary logical TOML fragment in
`${EDITOR:-vim}` with an empty `base_url`, `wire_api = "responses"`, and
`requires_openai_auth = false`. After validation, CCS prompts separately for
the API key with hidden terminal input. The logical fragment is stored at
`~/.codex/ccs-providers/<provider>.toml`; the key is stored independently at
`~/.codex/ccs-auth/<provider>.json`. Neither secret is printed or embedded in
the TOML fragment.

`ccs codex use <provider>` validates the logical fragment and its credential,
then atomically updates the fixed table and the `ccs-providers/current`
symlink while holding the CCS lock. Other top-level settings and sections are
preserved byte-for-byte. `current`, `list`, and `show` continue to report the
logical profile name. `~/.codex/auth.json` remains the global ChatGPT login and
is not rewritten during provider switching.

`ccs codex edit <provider>` edits only the logical fragment. Enter a new API
key to rotate its protected snapshot or leave the prompt blank to keep it. If
the edited profile is active, CCS refreshes `[model_providers.ccs]` in the same
transaction. Provider names cannot be changed in the editor; use `ccs codex
rename <old> <new>`.

`ccs codex rename <old> <new>` renames the logical main and nested tables,
moves its auth snapshot, and updates `current` plus the fixed table when the
profile is active. `ccs codex rm <name>` removes only an inactive logical
profile and its snapshot. Neither command renames or removes the fixed `ccs`
provider ID. The names `ccs` and `openai` are reserved; built-in `openai`
cannot be edited, renamed, or removed.

Third-party profiles materialize a managed `[model_providers.ccs.auth]` table
that reads their own `ccs-auth/<provider>.json`; they use
`requires_openai_auth = false`, so ChatGPT OAuth tokens are not sent to their
endpoints. The logical `openai` profile instead materializes the ChatGPT Codex
endpoint with `wire_api = "responses"` and `requires_openai_auth = true`, with
no third-party `.auth` table.

For a new machine, create the official subscription credential through Codex's
native browser login. CCS never handles the password or OAuth exchange itself;
after Codex finishes, CCS validates `auth.json` and stores the complete login:

```bash
ccs codex new openai
```

Use `ccs codex login` later to sign in again or refresh the managed OpenAI
credential. Native login runs with a process-only `model_provider="openai"`
override. After it exits, the on-disk config is immediately materialized back
to the fixed `ccs` ID and the logical `openai` profile becomes active.

```bash
ccs codex new proxy
ccs codex use proxy
ccs codex current
ccs codex show proxy
ccs codex use openai
```

On the first v0.6 command, CCS validates every legacy provider table and saved
credential before writing anything. It saves each table as a logical profile,
materializes the formerly active profile under the fixed `ccs` ID, removes the
legacy provider tables, and creates the `current` link. A mode-600 config backup
under `~/.codex/ccs-backups/` is retained and never modified by CCS. A fixed-ID
conflict, malformed provider TOML, missing credential, lock conflict, or
interruption leaves config, current, and credentials uncommitted or restored.
Older `.env` profiles are still imported before this migration, and their
timestamped read-only backup is retained.

Codex files:

| Path | Purpose |
|------|---------|
| `~/.codex/config.toml` | Fixed `model_provider = "ccs"` and the active `[model_providers.ccs]` table |
| `~/.codex/auth.json` | Official ChatGPT login used by Codex and Remote |
| `~/.codex/ccs-providers/<provider>.toml` | Logical provider definition and nested tables |
| `~/.codex/ccs-providers/current` | Symlink to the active logical provider profile |
| `~/.codex/ccs-auth/openai.json` | Protected backup of the complete ChatGPT login |
| `~/.codex/ccs-auth/<provider>.json` | Protected third-party key read through command auth |
| `~/.codex/ccs-backups/` | Protected pre-migration config backups |
