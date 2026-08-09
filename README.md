# rathena-docker

Multi-stage Docker build for [rAthena](https://github.com/rathena/rathena) — the Ragnarok Online server emulator. Compose stack for the login, char and map servers, a password page for players, and no game data baked into the image.

---

## Why this exists

rAthena publishes images on Docker Hub, but they were last rebuilt in **December 2025** while the source is committed to continuously — many months of drift on a server that has no versioning of its own.

The project's own `tools/docker/` is a **development environment, not a deployment**. It is Alpine plus `gcc`, `gdb` and `valgrind` with an empty `ENTRYPOINT`; its compose file mounts the whole git checkout into every container and builds in place; and it hardcodes the database password as `ragnarok` while publishing 3306 to the host. That is a reasonable way to hack on the emulator and the wrong way to run a shard people can reach.

So: build once, ship only what runs.

## Quick start

```bash
git clone https://github.com/heyvaldemar/rathena-docker.git
cd rathena-docker
cp .env.example .env          # change the passwords and RA_PUBLIC_IP
./render-conf.sh              # writes conf-import/ from .env
docker compose up -d --build
```

Load the schema once, from the image's own `sql-files`:

```bash
docker compose cp login:/rathena/sql-files ./sqlfiles
docker compose exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" ragnarok' \
  < sqlfiles/main.sql
docker compose exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" ragnarok' \
  < sqlfiles/logs.sql
```

The login server listens on 6900, char on 6121, map on 5121.

## What is in the image, and what is not

**In:** the three server binaries, the `db/` and `npc/` data they read at startup, the shipped `conf/`, and `sql-files` so the schema always matches the binaries that will talk to it.

**Not in:** any compiler, `git`, or debugger — those live in the build stage and are thrown away. No game client data of any kind.

**The era is compiled in.** `--enable-prere` selects pre-renewal, renewal is the default, and you cannot switch afterwards without rebuilding. `PACKETVER` is likewise a compile-time constant naming the client build your players use — get it wrong and clients disconnect at character select with nothing useful in the log. Both are `ARG`s, so changing either is a rebuild rather than an edit of a running server.

`RATHENA_REF` is a full 40-character commit SHA. rAthena has no releases, only a rolling master, so *the version is the commit*; pinning it is the difference between a rebuild that reproduces this server and one that produces a different one.

> `git fetch --depth 1 origin <ref>` will not resolve a shortened hash. The remote has to be asked for an object it can name exactly, so abbreviations fail with an unhelpful error.

---

## Errors this build already solves

If you arrived here from a search engine with one of these, the fix is already in the repository.

### `Access denied for user 'ragnarok'` — with the correct password

The log database has **its own set of keys**. Overriding every other credential and missing these leaves the login server falling back to the shipped defaults, which happen to use the same *username* as yours — so the error looks like a wrong password on a connection that is in fact a different connection entirely. The only clue is the file named in the debug line: `loginlog.cpp`.

```
log_db_ip / log_db_port / log_db_id / log_db_pw / log_db_db
```

All five are in `render-conf.sh`.

### `Invalid password` for the inter-server account, whose name is echoed back correctly

**The inter-server password is truncated at 23 characters.** It is read into a fixed 24-byte buffer, so a longer password is silently cut on the server side while the database keeps the whole thing.

Measured: a 24-character password was refused, and its first 23 characters were then accepted for the same account. Keep `RA_INTER_PASS` at 23 or fewer.

### The client authenticates, then hangs with an empty log

`char_ip` is what the login server hands the client as "now go here", and Ragnarok carries a **32-bit address** in that packet. A hostname is accepted by the config parser and then quietly breaks the hand-off. `RA_PUBLIC_IP` must be numeric.

### `Failed to open <TYPE> database file from 'conf/import/...'` on every start

rAthena looks for optional import files and logs an `[Error]` for each one that is absent — and they surface **one at a time**, so chasing them individually takes as many restarts as there are files. An error line that is always present is an error line nobody reads, and the next real one hides behind it.

`render-conf.sh` writes the full set. The YAML ones need a header, not merely existence:

```yaml
Header:
  Type: INTER_SERVER_DB
  Version: 1
Body: []
```

### Configuration keeps being overwritten by rebuilds

rAthena reads `conf/*.conf` and then overlays `conf/import/*`. Editing the shipped files means every image rebuild fights your settings; the import directory is the documented way in and survives untouched. This stack mounts `conf-import/` there read-only and generates it from `.env`.

---

## Security defaults worth changing

rAthena's shipped defaults suit a private LAN. Three of them do not suit a server strangers can reach.

### Passwords are stored in plain text

```
use_MD5_passwords: no
```

That is the default, and it means anyone who reaches the database reads every password in the clear — and people reuse passwords, so the damage does not stop at your game.

`render-conf.sh` turns it on. Migrating an existing server is one statement, because the hash is applied to what the *client* sends, so the md5 of the stored plaintext is exactly what the server will compare against:

```sql
UPDATE login SET user_pass = MD5(user_pass)
 WHERE user_pass NOT REGEXP '^[0-9a-f]{32}$';
```

That covers the inter-server account too, which authenticates through the same path (`loginclif.cpp` hashes it at line 411 just as it does a player at 279).

**What it costs:** with MD5 storage the server *rejects* client-side password encryption outright — the two are mutually exclusive by design, because the challenge-response mode computes `md5(session_key + stored_password)` and therefore needs the stored password in the clear. So this protects the database at the cost of the password crossing the network unencrypted. Ragnarok has no TLS either way, and the database is the likelier leak.

### The shipped DNS blocklist is half dead

```
dnsbl_servers: bl.blocklist.de, socks.dnsbl.sorbs.net
```

**SORBS shut down in 2024.** Its zone answers `NXDOMAIN`, so with `use_dnsbl: yes` every single login pays for a DNS lookup that can never match. Verified against the control address `127.0.0.2`, which every working blocklist answers by convention:

| list | answer for `127.0.0.2` | |
|---|---|---|
| `bl.blocklist.de` | `127.0.0.2` | alive — SSH/FTP/IMAP attackers |
| `socks.dnsbl.sorbs.net` | NXDOMAIN | dead |
| `dnsbl.dronebl.org` | `127.0.0.1` | alive — proxies, drones, botnets |
| `zen.spamhaus.org` | `127.255.255.254` | refuses public resolvers |

Test any blocklist before trusting it: a zone whose domain has been re-registered can answer *everything*, and then it blocks all your players at once.

### Self-registration is off, and its convention is undocumented

`new_account: no` is the default, so the first person to try gets "account does not exist" with no way to make one. With it on, registration happens by appending `_M` or `_F` **to the username** — not the password, which is the version repeated all over the web and the one that does not work:

```c
sd->userid[len-2] == '_' && memchr("FfMm", sd->userid[len-1], 4)
```

Registration also logs you straight in: `login_mmo_auth_new` returns `-1` on success and the caller falls through to normal authentication. Saying so matters, because a player who expects an error will retype things after it has already worked.

---

## The password page

**Ragnarok has no in-game password command.** All 314 registered atcommands were checked; there is `accinfo` and `changesex`, and nothing for a password. Without something outside the game, every reset goes through you by hand.

`webpw/` is that something: one form, one column of one row, no session, no cookie, no admin view, no account listing. An attacker who fully compromises it gains what a player already has.

### Why not FluxCP

rAthena's own control panel is the obvious answer, and it was rejected on evidence rather than taste. An open security audit filed **2026-03-04** lists **8 vulnerabilities, 2 of them CRITICAL** — including SQL injection in `modules/servicedesk/staffview.php`, where a ticket id is interpolated straight into a query. The report's own words: *"enables full database compromise."* Five months later there is no reply on the issue. The project's last commit is 2025-11-03, and it has taken roughly thirty commits in two years.

That is a large PHP application, publicly exposed, holding credentials to the account database, with known unfixed holes. If you need a full control panel, weigh that. If you only need players to change their own passwords, 250 readable lines are a better trade.

The page uses parameterised queries throughout — the exact thing FluxCP got wrong — returns an identical message for every failure so it cannot be used to enumerate account names, and rate-limits by address.

```bash
docker compose up -d webpw
```

It binds `127.0.0.1:8090`. Put a reverse proxy or tunnel in front of it: the page takes passwords and has no business on plain HTTP.

## tools/set-password.sh

The web page needs the current password, which is no help when nobody knows it
any more. This sets one from the host — one parameterised `UPDATE`, the new
password written to a mode-600 file rather than printed, and the result checked
by performing a real login rather than assuming the write took.

```bash
tools/set-password.sh someaccount
```

## tools/grf.py

A minimal reader for Ragnarok's GRF archives — enough to list entries and pull one out.

It exists because client packs sometimes carry surprises. The widely-linked pre-renewal pack replaces **all seventeen** of the client's web-link slots in `data\msgstringtable.txt` — the homepage, the cash shop, "Purchase", "Dealer", and the one the client opens for "Please change your password" — with the pack author's YouTube channel. Closing the in-game settings window is enough to launch a browser at it. Nothing in the executable contains that address in any encoding; it is inside a compressed GRF entry, invisible to a string search over the file.

```python
import grf
for f, name, csize, rsize, flags, off in grf.entries("prerenewal.grf"):
    if name.lower().endswith(b"msgstringtable.txt"):
        open("out.txt", "wb").write(grf.read(f, csize, rsize, flags, off))
```

Correcting it does not need the archive repacked: **the client reads loose files in `data/` before it reads the GRFs**, so a corrected copy next to the executable wins. That table is addressed by index, so preserve the line count exactly — adding or removing one silently shifts every message after it.

## Game data

Nothing in this repository is Ragnarok Online client data, and none is baked into the image. rAthena is a server emulator; the client, its sprites, maps and music are Gravity's, and supplying them is between you and your players.

## Legal

**rAthena is licensed GPL-3.0.** This repository contains build tooling — a Dockerfile, a compose stack, a configuration generator and a small web page — not rAthena's source, which is fetched from upstream at build time. Distributing an image built from this Dockerfile means distributing GPL-3.0 software and taking on its obligations, including making the corresponding source available. Building for your own use carries no such obligation.

**Ragnarok Online is copyright Gravity Co., Ltd.** No client files are in this repository, in the image, or in the build.

## Licence

The contents of this repository are MIT-licensed. rAthena itself remains GPL-3.0 and is not covered by that grant.
