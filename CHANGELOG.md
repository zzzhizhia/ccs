# Changelog

All notable changes to CCS are documented in this file.

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

[0.6.1]: https://github.com/zzzhizhia/ccs/releases/tag/v0.6.1
[0.6.0]: https://github.com/zzzhizhia/ccs/releases/tag/v0.6.0
