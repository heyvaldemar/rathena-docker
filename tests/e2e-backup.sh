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
PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
cleanup() { docker rm -f "$RUN-db" "$RUN-bk" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

echo "=== the backup sidecar, against a real database ==="
echo "image: $IMAGE"
chmod 0777 "$WORK"

docker run -d --name "$RUN-db" \
  -e MARIADB_ROOT_PASSWORD=rootpw -e MARIADB_DATABASE=ragnarok \
  -e MARIADB_USER=rauser -e MARIADB_PASSWORD=rapw "$IMAGE" >/dev/null
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

# The command below is the compose file's, with the waits removed so this
# finishes in seconds. If they drift apart this test stops describing the
# thing it is named after, so the shape is taken from the file itself.
backup_once() {  # <user> <password> -> runs one iteration
  docker rm -f "$RUN-bk" >/dev/null 2>&1
  docker run --rm --name "$RUN-bk" --link "$RUN-db:db" -v "$WORK:/backups" \
    -e RA_DB_USER="$1" -e RA_DB_PASSWORD="$2" "$IMAGE" \
    bash -c 'set -o pipefail;
      F=/backups/rathena-db-backup-test.gz;
      if mariadb-dump -h db -u "$RA_DB_USER" -p"$RA_DB_PASSWORD" --single-transaction --quick ragnarok | gzip > "$F.partial" && gzip -t "$F.partial"; then
        mv "$F.partial" "$F"; echo BACKUP_OK;
      else
        mv "$F.partial" "$F.failed" 2>/dev/null || true; echo BACKUP_FAILED;
      fi' 2>/dev/null
}

out="$(backup_once rauser rapw)"
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

echo
echo "=== $PASSED passed, $FAILED failed ==="
[ "$FAILED" -eq 0 ]
