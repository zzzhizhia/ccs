# Changelog

All notable changes to CCS are documented in this file.

## [0.6.4] - 2026-08-17

### Added

- Added `ccs codex doctor` for read-only dependency, provider, migration, and
  masked authentication diagnostics with executable remediation commands.
- Added distinct `missing`, `invalid`, `chatgpt`, and `apikey` credential
  states to Codex provider listing and inspection.

### Fixed

- Made missing and malformed OpenAI credentials direct users to install the
  standalone Codex CLI when necessary and run `ccs codex login`.
- Allowed native login to recover an invalid OpenAI credential safely before
  migration, while preserving transaction rollback on cancelled login.
- Checked for the Codex CLI before initializing or migrating Codex state during
  official login.

### Validation

- Added regression coverage for missing CLI installation guidance, missing,
  empty, and directory-shaped credentials, pre-migration login recovery,
  doctor recommendations, and rollback after a native login writes partial
  authentication state and fails.

## [0.6.3] - 2026-08-08

### Changed

- Removed redundant `base_url` and `wire_api` fields from the official Codex
  subscription profile while retaining the fixed `ccs` provider identity,
  OpenAI display identity, and `requires_openai_auth = true` semantics.
- Added an idempotent, transaction-protected migration with mode-400 backups
  for existing official Codex profiles and active configs.
- Strengthened `ccs unset` to clear every CCS-managed variable plus variables
  declared by the active Claude profile, including sparse and dangling states.
- Added native fish variable-erasure output for shell-evaluated CCS commands.

### Validation

- Added migration idempotence and rollback coverage, official Codex minimal
  config assertions, and Claude official subscription mode tests.

## [0.6.2] - 2026-08-07

### Fixed

- Skip rewriting the active statusline script when its generated content and
  executable state are unchanged during shell startup.
- Ignore statusline materialization filesystem failures during initialization so
  restoring the active profile environment can continue.

## [0.6.1] - 2026-07-30

### Fixed

- Fixed fixed-provider migration being blocked by an unrelated inactive legacy
  provider with an incomplete definition or no saved credential. Inactive
  providers are now preserved for later repair, while the active provider and
  every subsequent switch remain strictly validated.

## [0.6.0] - 2026-07-30

### Added

- Added `ccs rename` for Claude profiles and statusline bindings.
- Added `ccs codex rename` for logical provider profiles and their saved auth.
- Added protected, one-time migration from legacy Codex provider tables to
  `~/.codex/ccs-providers/`, including rollback and read-only config backups.

### Changed

- Codex now always sees the fixed `model_provider = "ccs"` identity while users
  continue switching logical profiles such as `openai` and `proxy`.
- Codex provider definitions, active state, and auth snapshots are managed as
  separate files so switching upstream services does not hide existing App
  conversations or overwrite the global ChatGPT login.
- Provider creation, editing, switching, login, removal, and rename operations
  now use lock-protected transactions with failure and interruption recovery.

### Validation

- Expanded Codex file-mode coverage for fixed provider materialization,
  byte-preserving switches, migration conflicts, lock contention, interrupted
  commits, credential preservation, and active/inactive rename behavior.

[0.6.4]: https://github.com/zzzhizhia/ccs/releases/tag/v0.6.4
[0.6.3]: https://github.com/zzzhizhia/ccs/releases/tag/v0.6.3
[0.6.2]: https://github.com/zzzhizhia/ccs/releases/tag/v0.6.2
[0.6.1]: https://github.com/zzzhizhia/ccs/releases/tag/v0.6.1
[0.6.0]: https://github.com/zzzhizhia/ccs/releases/tag/v0.6.0
