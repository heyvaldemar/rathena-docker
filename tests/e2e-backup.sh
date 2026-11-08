#!/usr/bin/env bash
# Does the backup sidecar tell a real dump from a file named like one?
#
# Every account, character and item on a shard lives in the db service and
# nowhere else. A backup that writes a file and never reads it back is the
# failure this fleet has already been bitten by: the archive is named as a
# backup, a restore picks it, and it does not open.
#
# So both directions are exercised against a real MariaDB. A healthy dump has
# to appear, open, and contain the schema; a dump that cannot be taken has to
# leave nothing under the name a restore would choose.
#
#   ./tests/e2e-backup.sh
#
# Needs docker. Everything it creates is named for this run and removed on
# exit, including on failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="$(grep -m1 -oE '\$\{RA_DB_IMAGE_TAG:-.*' "$ROOT/docker-compose.yml" \
  | sed -E -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta' | sed 's/}*$//')"
RUN="rabackup-$$"
WORK="$(mktemp -d)"
# The database user's password, random per run: the probe below looks for it
# on every command line, and a word that also appears in this file would be
# found where it is only a literal.
RA_PW="$(openssl rand -hex 12)"
PW_FILE="$(mktemp)"; chmod 600 "$PW_FILE"; printf '%s\n' "$RA_PW" > "$PW_FILE"
PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
cleanup() { docker rm -f "$RUN-db" "$RUN-bk" >/dev/null 2>&1; rm -rf "$WORK" "$PW_FILE"; }
trap cleanup EXIT

echo "=== the backup sidecar, against a real database ==="
echo "image: $IMAGE"
chmod 0777 "$WORK"

MARIADB_PASSWORD="$RA_PW" docker run -d --name "$RUN-db" \
  -e MARIADB_ROOT_PASSWORD=rootpw -e MARIADB_DATABASE=ragnarok \
  -e MARIADB_USER=rauser -e MARIADB_PASSWORD "$IMAGE" >/dev/null
ready=false
for _ in $(seq 1 40); do
  if docker exec "$RUN-db" mariadb -uroot -prootpw -e 'select 1' >/dev/null 2>&1; then ready=true; break; fi
  sleep 3
done
[ "$ready" = true ] || { echo "the database never accepted a query — the fixture failed, not the sidecar"; exit 1; }

# A schema worth losing, so "it restored nothing" is distinguishable from
# "it restored everything" by something other than the file existing.
docker exec "$RUN-db" mariadb -uroot -prootpw -e "
  create table ragnarok.login(account_id int primary key, userid varchar(24));
  insert into ragnarok.login values (2000000,'admin'),(2000001,'player');" >/dev/null 2>&1

# THE DUMP, WITH THE SIDECAR'S OWN LINE. A copy of it here would be a test of
# the copy, so the line is read out of the compose file, as the prune line is
# below, and run in the loop's shape with the waits removed. The dollar signs
# are the compose file's $$, turned back into one.
# shellcheck disable=SC2016
dump_line="$(grep -oE 'MYSQL_PWD="\$\$RA_DB_PASSWORD" mariadb-dump [^|]*' "$ROOT/docker-compose.yml" | head -1 | sed 's/\$\$/$/g')"
[ -n "$dump_line" ] || { echo "the compose file carries no dump line this test recognises (MYSQL_PWD=... mariadb-dump)"; exit 1; }
# shellcheck disable=SC2016  # expanded by bash inside the container, not here
script='set -o pipefail; F=/backups/rathena-db-backup-test.gz;
  if '"$dump_line"'| gzip > "$F.partial" && gzip -t "$F.partial"; then
    mv "$F.partial" "$F"; echo BACKUP_OK;
  else
    mv "$F.partial" "$F.failed" 2>/dev/null || true; echo BACKUP_FAILED;
  fi'
backup_once() {  # <user> <password> -> runs one iteration
  docker rm -f "$RUN-bk" >/dev/null 2>&1
  RA_DB_USER="$1" RA_DB_PASSWORD="$2" docker run --rm --name "$RUN-bk" --link "$RUN-db:db" -v "$WORK:/backups" \
    -e RA_DB_USER -e RA_DB_PASSWORD -e RA_DB_NAME=ragnarok "$IMAGE" bash -c "$script" 2>/dev/null
}

out="$(backup_once rauser "$RA_PW")"
if [ -f "$WORK/rathena-db-backup-test.gz" ] && printf '%s' "$out" | grep -q BACKUP_OK; then
  pass "a healthy dump lands under the name a restore would pick"
else
  fail "no dump was produced from a working database"
fi
if gzip -t "$WORK/rathena-db-backup-test.gz" 2>/dev/null; then
  pass "and the file it wrote opens"
else
  fail "the file it wrote does not open"
fi
if gzip -cd "$WORK/rathena-db-backup-test.gz" 2>/dev/null | grep -q "CREATE TABLE \`login\`"; then
  pass "and carries the schema, not just bytes"
else
  fail "the dump does not contain the table that was there"
fi
if gzip -cd "$WORK/rathena-db-backup-test.gz" 2>/dev/null | grep -q "2000001"; then
  pass "and the rows with it"
else
  fail "the dump carries the schema but not the data"
fi

# NO PASSWORD ON A COMMAND LINE, read while the dump runs. A process's
# arguments are readable by every user on the host, so the password reaches
# mariadb-dump as MYSQL_PWD and docker by name. A write lock on the table the
# dump has to read keeps it waiting; every command line on this machine and in
# the sidecar's container is read meanwhile, and none may hold the password,
# compared through a file, so it is never printed.
echo "=== the dump, read while it runs ==="
docker exec -d "$RUN-db" mariadb -uroot -prootpw -e 'LOCK TABLES ragnarok.login WRITE; SELECT SLEEP(90)'
lock_id=""
for _ in $(seq 1 30); do
  lock_id="$(docker exec "$RUN-db" mariadb -uroot -prootpw -N -e "SELECT id FROM information_schema.processlist WHERE info LIKE 'SELECT SLEEP(%' LIMIT 1" 2>/dev/null)"
  [ -n "$lock_id" ] && break
  sleep 1
done
rm -f "$WORK"/rathena-db-backup-test.gz*
backup_once rauser "$RA_PW" > "$WORK/held.out" &
held=$!
dump=""
for _ in $(seq 1 60); do
  dump="$(ps -eo comm=,args= | awk '$1 == "mariadb-dump" { $1 = ""; sub(/^ /, ""); print; exit }')"
  [ -n "$dump" ] && break
  sleep 1
done
# shellcheck disable=SC2009  # every command line on the machine, not one process
hits_host="$(ps -eo args= | grep -cF -f "$PW_FILE" || true)"
hits_ctr="$(docker exec "$RUN-bk" sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\000" " " < "$f" 2>/dev/null; echo; done' 2>/dev/null | grep -cF -f "$PW_FILE" || true)"
[ -n "$lock_id" ] && docker exec "$RUN-db" mariadb -uroot -prootpw -e "KILL $lock_id" >/dev/null 2>&1
wait "$held"
echo "  the dump, read while it ran: $(printf '%s' "$dump" | sed -E 's/(^| )(-p|--password=?)[^ ]*/\1\2<hidden>/g')"
if [ -z "$lock_id" ] || [ -z "$dump" ]; then
  fail "the dump was never seen running (lock ${lock_id:-not taken})"
elif [ "$hits_host" = 0 ] && [ "$hits_ctr" = 0 ] && ! printf '%s' "$dump" | grep -qE '(^| )(-p[^ ]*|--password[^ ]*)( |$)'; then
  pass "no command line on the host or in the container carried the password while the dump ran, and the dump has no -p"
else
  fail "the password was on a command line while the dump ran: host $hits_host, container $hits_ctr, dump: $(printf '%s' "$dump" | sed -E 's/(^| )-p[^ ]*/\1-p<hidden>/g')"
fi
if grep -q BACKUP_OK "$WORK/held.out" && [ -f "$WORK/rathena-db-backup-test.gz" ]; then
  pass "and once the lock went, that dump finished"
else
  fail "the held dump did not finish once the lock went"
fi

# THE DIRECTION THAT MATTERS. A dump that cannot be taken must not leave a
# file under the name a restore would choose.
rm -f "$WORK"/rathena-db-backup-test.gz*
out="$(backup_once rauser wrong-password)"
if [ ! -f "$WORK/rathena-db-backup-test.gz" ]; then
  pass "a refused login leaves nothing a restore would pick up"
else
  fail "a refused login still produced a file named like a backup"
fi
if [ -f "$WORK/rathena-db-backup-test.gz.failed" ] && printf '%s' "$out" | grep -q BACKUP_FAILED; then
  pass "and keeps the attempt as .failed, and says so"
else
  fail "the failure left nothing to diagnose"
fi

# THE PRUNE, WITH THE SIDECAR'S OWN LINE. The loop in docker-compose.yml
# deletes archives older than RA_BACKUP_PRUNE_DAYS with one find. A copy of
# that line here would be a test of the copy, so the line is read out of the
# compose file and run from the same image: a file dated 2020 has to go, a
# fresh one has to stay. Nothing exercised this until 2026-09-25.
echo "=== the prune, with the sidecar's own line ==="
# The dollar signs are the point: the compose file escapes them as $$, and the
# pattern has to match that literally before it is turned back into one.
# shellcheck disable=SC2016
prune_line="$(grep -oE 'find "\$\$RA_BACKUPS_PATH"[^;]*-delete' "$(dirname "$0")/../docker-compose.yml" | head -1 | sed 's/\$\$/$/g')"
if [ -z "$prune_line" ]; then
  fail "the compose file carries no prune line this test recognises"
else
  touch -t 202001010000 "$WORK/rathena-db-backup-2020-01-01_00-00.gz"
  touch "$WORK/rathena-db-backup-fresh.gz"
  docker run --rm -v "$WORK:/backups" -e RA_BACKUPS_PATH=/backups -e RA_BACKUP_NAME=rathena-db-backup \
    -e RA_BACKUP_PRUNE_DAYS=7 "$IMAGE" bash -c "$prune_line" 2>/dev/null
  if [ ! -f "$WORK/rathena-db-backup-2020-01-01_00-00.gz" ]; then
    pass "a file dated 2020 is pruned by the shipped line"
  else
    fail "a file dated 2020 survived the shipped prune line"
  fi
  if [ -f "$WORK/rathena-db-backup-fresh.gz" ]; then
    pass "and a fresh one stays"
  else
    fail "the prune took a fresh file with it"
  fi
fi

echo
echo "=== $PASSED passed, $FAILED failed ==="
[ "$FAILED" -eq 0 ]
