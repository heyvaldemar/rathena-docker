# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Both stages of the server image build on `alpine:3.24` pinned by digest, and the password page on `python:3.13-alpine` pinned the same way.** The server's base was `ARG ALPINE=3.24` and `FROM alpine:${ALPINE}`, the password page's `FROM python:3.13-alpine`: each build took whatever the tag named that day, and nothing could compare it with anything. alpine 3.24.4 came out on 2026-11-05 and no check could see it. The pins are today's digests (alpine 3.24.4; Python 3.13.18 on alpine), so a build made now is the same image as before, and a tag repushed upstream is now a drift the freshness check reports.

### Fixed

- **The freshness check reads the bases and the database.** It compared only `RATHENA_REF`. A second job now compares the two `FROM` pins and `RA_DB_IMAGE_TAG` (`mariadb:11.8`, pinned by digest and compared by nothing until now) with what each tag names today, and fails on a new build. An index pushed again over the same linux/amd64 image is named and is not a failure: the stack runs, and CI proves, linux/amd64. On the day it was added, `mariadb:11.8` already named a newer build than the pin.

### Changed

- **The health checks ask the servers, not their ports.** Each was `netstat -ltn | grep -q :<port>`, which a stopped or hung server passes with its listening socket. `tools/healthcheck.sh`, mounted read-only, now asks each server what a game client asks it and is healthy only on its reply: the login-server's password-hash key (0x01db, answered 0x01dc), the char-server's echo of a client's account on connect (0x0065, account 1234567, never a real one), the map-server's refusal (0x006a) of a client's CZ_ENTER for account 0, sent in the 23-byte form so any PACKETVER refuses it. busybox only; nc gives up after 3 seconds. Each check leaves its server a line or two in the log, so the interval is 60 seconds instead of 30. It asks from inside the containers, so it does not prove the ports are published on the host or open in a firewall, nor that the servers have logged in to each other; the README says so. CI stops each server with SIGSTOP and requires its check red while the old `netstat` check stays green, then green again after SIGCONT.

## [1.6.1] - 2026-11-08

### Security

- **No password is on any command line any more.** The backup loop ran `mariadb-dump -p"…"`; `tools/set-password.sh` and `tools/set-inter-account.sh` ran `mariadb -p"$MARIADB_ROOT_PASSWORD"` with the new account password inside the `-e` statement; the README's schema load used `-p` too. A process's arguments are readable by every user on the host with `ps` (`/proc/<pid>/cmdline` is world-readable, and the host sees every container's processes). The client overwrites its `-p` copy once it has parsed it, but only after it was readable, and leaves the password's length on show as a row of `x`; the `-e` statement it never overwrote. Now every client reads `MYSQL_PWD`, and the two tools send their statement on stdin from the shell's own `printf`. Verified on the pinned `mariadb:11.8`: the variable is read (a wrong value is refused with 1045) and no warning is printed. `tests/e2e-backup.sh` now runs the dump line read out of the compose file, holds one dump open on a table lock and reads every command line on the runner and in the sidecar meanwhile: none may carry the password (compared through a file, never printed), and the dump may carry no `-p`.

## [1.6.0] - 2026-11-02

### Fixed

- **The first start now gives the char-server an account it can log in with.** The schema creates the inter-server account as `s1` / `p1`, while `render-conf.sh` tells char and map to log in as `RA_INTER_USER` / `RA_INTER_PASS`, and nothing in the README or CI changed the row. A stack started as the Quick start says ran with the login server refusing the char-server ("Unknown account") and turning away every player whose password was right ("there is no char-server online"), with all three containers healthy, because the healthchecks only look at listening ports. CI ran that way too, and its comment said a healthy map-server meant the whole chain was connected. New `tools/set-inter-account.sh` updates account 1 from `.env` (the password hashed to md5 on the host and passed in the environment) and waits for the login server to accept the char-server. The README's first start runs it, and CI runs it twice: after the schema loads, and again once the servers are up, where it fails unless the login server has accepted the char-server. The new end-to-end test of `tools/set-password.sh` found it: the login server answered "Authentication accepted", then refused for want of a char-server.
- **`tools/set-password.sh` checks the new password with a real login, as it always said it did.** The check's python carried `${RA_PACKETVER:-20200401}` inside single quotes, so python received it as written: a `SyntaxError` from the first version on. The run stopped there with exit 1, after writing the password file, and nothing ever exercised the check. The packet version now travels in the environment. The answer is read by its packet: 0x0069 or 0x0AC4 is accepted; 0x0081 is sent only after the password was accepted (code 1, most often no char-server online), so the password counts as proven; anything else is refused, and a refused login exits 1.
- **A password that may be in effect is never thrown away.** The UPDATE runs through `docker exec`, and an exec killed by a restart ends with 137 and prints nothing (measured on Docker 29.7.2), possibly after the UPDATE ran. The script read that as "FAILED: no account" and wrote no file, which leaves an account with a password nobody holds. The new password is now written to `secrets/ro-<account>-password.new` before the database sees it and moves into place once the database or the login proves it. Docker refusing the exec before it started (exit 1, or 128 with "cannot exec in a stopped state" on stdout, which used to surface as "integer expression expected" and "no account") now says the UPDATE did not run.
- **The new password is no longer on a command line.** `docker exec` and `docker run` took it as `-e P=<password>`, where anyone on the host could list it; both now take it from the environment.
- `tests/set-password.sh` plays the database through a fake `docker` and runs the login check's own python against a stand-in login server that answers as `loginclif.cpp` does; the released script fails it. `tests/e2e-set-password.sh` sets a scratch account's password against the real stack, with a wrong password refused as the control.

## [1.5.0] - 2026-10-28

### Fixed

- **A new database no longer leaves the servers on dead connections.** login, char and map hold their MariaDB connections open, and an update that recreated `db` alone (a new MariaDB digest is the usual one) left them on sockets to a server that was gone. Every healthcheck stayed green, because the healthchecks only see the listening ports, and the next login was the query that failed. All three now depend on `db` with `restart: true`: when compose recreates `db`, it stops the three, then starts login, char and map in that order, each healthy before the next. `restart: true` does not cascade through `login`, which is why each server names `db` itself. `tests/e2e-db-recreate.sh` recreates `db` the way an update does and reads each server's sockets to port 3306 from the kernel table; CI also runs it with `db` recreated alone and requires that run to fail. Needs Docker Compose 2.17 or newer.

### Added

- **CI fails on an anonymous volume.** A `VOLUME` an image declares and no mount covers becomes an anonymous volume: never backed up, and replaced by an empty one on `down`/`up`. The deployment verification now inspects every container it starts and fails on one, unless `.github/anonymous-volumes` lists it with the reason. GLPI's data lived in exactly such a volume from 2026-08-31 to 2026-10-11.

## [1.4.2] - 2026-10-06

### Changed

- **rAthena moved from upstream `e985006` to `d4b8e7b`.** Two commits, both data: a duplicate refine key removed from the Gaebolg
  Muffler in `db/re/item_db_equip.yml` and a duplicate trade block from the Sinulog Hat in `db/re/item_group_db.yml`. No SQL file
  changed, so an existing database needs no upgrade script. CI rebuilt the server from the new commit and booted login, char and map.

## [1.4.1] - 2026-10-06

### Security

- **`mariadb:11.8` was rebuilt upstream**; the pin moved from `sha256:2439dcd7d140…` to `sha256:6422478cb8e1…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

### Changed

- **The freshness check has its own workflow, Pin Freshness.** It ran inside Deployment Verification, whose badge is the one at the top of this README. Across the fleet, nine red runs in ten were a pin one version behind - which the fleet's triage moves within the day - and a reader cannot tell that from a stack that does not boot. The badge now says whether the stack boots. The job itself is unchanged.

### Fixed

- **`update.sh` no longer stops without a word when a release adds a variable and no compose file requires one.** The search for `${VAR:?}` came back empty, and under `pipefail` that empty result ended the script with status 1 right after it listed the new variables.
- **`update.sh` stops on a `.env` it cannot read, before the checkout.** It used to fall through: every new required variable read as "not set", or, with none, the tree moved to the new tag and `docker compose up` failed on the permission. Now it names the file, its owner and mode, and changes nothing.

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

[Unreleased]: https://github.com/heyvaldemar/rathena-docker/compare/v1.6.1...HEAD
[1.6.1]: https://github.com/heyvaldemar/rathena-docker/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.4.2...v1.5.0
[1.4.2]: https://github.com/heyvaldemar/rathena-docker/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/heyvaldemar/rathena-docker/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/rathena-docker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/rathena-docker/releases/tag/v1.0.0
