# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.4.0] - 2026-09-22

### Added

- **A backup for the shard database, which had none.** Every account, character and item in this stack lives in the `db` service and nowhere else; rAthena offers no export and losing that volume leaves a fresh install with the same name. The new `backups` sidecar dumps it on an interval with `--single-transaction --quick`, so a live shard is neither locked nor buffered through the sidecar's memory, and prunes dumps older than `RA_BACKUP_PRUNE_DAYS`.

- **The dump is read back before it is renamed.** It is written to `.partial`, tested with `gzip -t`, and only then moved into the name a restore would pick; a dump that could not be taken is kept as `.failed` for diagnosis and leaves nothing under the real name. `tests/e2e-backup.sh` is shown both directions against a real MariaDB — a healthy dump that opens and carries the rows, and a refused login that produces no backup at all.

## [1.3.0] - 2026-09-07

### Added

- **`update.sh`: move between release tags on purpose.** It updates to the latest release (a combination this repository's CI has booted and smoke-tested), refuses to cross a major version unattended, refuses to run over local changes, and names any new required variable before anything has moved. `--dry-run` says what would happen.
- **A shutdown grace period for the database.** Docker allows ten seconds and
  then sends SIGKILL. MariaDB has InnoDB to flush on the way out, and a shard
  database cut off halfway does crash recovery on the next start, with a game
  world's state behind it.

atabase is
  pulled, so it carries a digest.
- **Resource limits on all five services**, as `.env`-overridable defaults.
  With no ceiling the kernel's out-of-memory killer picks its victim by size,
  so the process it kills is rarely the one at fault.
- **A Trivy scan of the pinned database image in CI**, reading the reference out
  of the `x-images` block rather than being told it a second time.
- **This changelog.** The two releases below are reconstructed from the tags
  that already existed.

## [1.1.0] - 2026-09-01

### Changed

- rAthena bumped to upstream `e985006`.

## [1.0.0] - 2026-09-01

### Added

- rAthena's login, char and map servers, their database and a password page,
  configured together from `.env` by `render-conf.sh` because the three servers
  are one program split three ways and have to agree about each other's
  addresses.
- **Nothing publishes the database.** rAthena's own `tools/docker/` publishes
  3306 to the host with a known password, which is fine for a laptop and wrong
  for anything reachable from outside.
- Deployment Verification CI: linting, a source freshness check, and a build
  that boots all four services and smoke-tests them, with the schema loaded
  before the servers start.

[Unreleased]: https://github.com/heyvaldemar/rathena-docker/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/rathena-docker/releases/tag/v1.0.0
