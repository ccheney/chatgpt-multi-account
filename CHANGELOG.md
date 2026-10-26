# Changelog

## v0.1.0 — 2026-10-26

First packaged release of the ChatGPT Multi-Account Desktop Launcher.

### Fixed

- Detect the newer `Contents/Resources/codex-cli/bin/codex` CLI layout while
  retaining support for legacy `Contents/Resources/codex` bundles (#3, #4).
- Require the bundled CLI to be an executable file; ignore directories and
  fall back to a valid legacy CLI when available.
- Share `thread_history_*.sqlite` and its WAL/SHM sidecars when detected, so
  shared conversations include their contents on newer desktop builds (#4).
- Include thread-history databases and sidecars in targeted secondary-home
  backups before replacing them.
- Keep process-detection search values out of the checker's arguments to
  prevent false "already running" results during launch and reset.

### Included

- Isolated secondary OAuth accounts, named accounts, and multiple-account
  setup for current ChatGPT and legacy Codex desktop bundles.
- Optional shared project/chat history, database-version detection, targeted
  or full backups, dry runs, and managed-account reset.
- Separate auth and pending-message queues; runtime database sharing remains
  an explicit opt-in.
- 26 integration tests and macOS/Linux CI covering bundle compatibility,
  history sharing, backup and reset behavior, launch isolation, and SQLite
  writes and locking.
- Updated installation, compatibility, shared-history, and testing guidance.

Thanks to @Aniket-Mishra and @JMacLulich for the compatibility and shared-history
contributions.
