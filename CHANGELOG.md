# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.2.0] - 2026-09-05

### Added

- **Image pins in an `x-images` block, as interpolation defaults.** Nothing has
  to be set in `.env` to start, and `git pull` delivers the combination this
  repository has tested. Two of the three images are built from this checkout,
  so their defaults name the local tag `build:` produces; the database is
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

[Unreleased]: https://github.com/heyvaldemar/rathena-docker/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/rathena-docker/releases/tag/v1.0.0
