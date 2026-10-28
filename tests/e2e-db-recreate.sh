#!/usr/bin/env bash
# Does a new database take the servers' old connections with it?
#
# login, char and map hold their MariaDB connections open for hours. An update
# that recreates db alone leaves them on sockets to a server that is gone, and
# every healthcheck stays green, because the healthchecks only look at the
# listening ports. The compose file makes compose restart all three whenever
# it recreates db. This test recreates db the way an update does, then reads
# what each server is left holding.
#
#   ./tests/e2e-db-recreate.sh             the stack as shipped: must pass
#   SABOTAGE=1 ./tests/e2e-db-recreate.sh  db recreated alone (--no-deps),
#                                          as before 2026-10-28: must fail
#
# Needs the stack up and healthy (the build-and-test job leaves it so). db is
# recreated by pointing RA_DB_IMAGE_TAG at the pinned image under another
# spelling of the same digest: compose sees a new configuration, while the
# server version and the data stay the same.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
started() { docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null; }
health() { docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null; }

digest="$(grep -m1 'mariadb: &mariadb-image' docker-compose.yml | grep -oE 'sha256:[0-9a-f]{64}')"
[ -n "$digest" ] || { echo "  FAIL: no pinned mariadb digest in docker-compose.yml"; exit 1; }
if [ "${SABOTAGE:-0}" = 1 ]; then
  ref="docker.io/library/mariadb@$digest"
  echo "=== a new database, recreated alone (sabotage: this run must fail) ==="
else
  ref="mariadb@$digest"
  echo "=== a new database under the servers' old connections ==="
fi
echo "db image for this run: $ref"

db_before="$(docker inspect -f '{{.Id}}' ra-db 2>/dev/null)"
login_before="$(started ra-login)"; char_before="$(started ra-char)"; map_before="$(started ra-map)"
[ -n "$db_before" ] && [ -n "$login_before" ] && [ -n "$char_before" ] && [ -n "$map_before" ] \
  || { echo "  FAIL: the stack is not running; start it first"; exit 1; }

if [ "${SABOTAGE:-0}" = 1 ]; then
  RA_DB_IMAGE_TAG="$ref" docker compose up -d --no-deps db
else
  RA_DB_IMAGE_TAG="$ref" docker compose up -d
fi

# map binds 5121 last, after its own map load, so healthy can take minutes.
deadline=$(( $(date +%s) + 600 ))
until [ "$(health ra-db) $(health ra-login) $(health ra-char) $(health ra-map)" = "healthy healthy healthy healthy" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "  db=$(health ra-db) login=$(health ra-login) char=$(health ra-char) map=$(health ra-map)"
    break
  fi
  sleep 5
done

if [ "$(docker inspect -f '{{.Id}}' ra-db 2>/dev/null)" != "$db_before" ]; then
  pass "db was recreated, as an update recreates it"
else
  fail "db was not recreated, so nothing below was tested"
fi

login_after="$(started ra-login)"; char_after="$(started ra-char)"; map_after="$(started ra-map)"
for pair in "login $login_before $login_after" "char $char_before $char_after" "map $map_before $map_after"; do
  # shellcheck disable=SC2086  # the pair is split into its three words on purpose
  set -- $pair
  if [ "$2" != "$3" ]; then pass "$1 was restarted with the new database"; else fail "$1 is still the process from before the new database"; fi
done
# RFC 3339 timestamps from one clock sort as strings.
if [[ "$login_after" < "$char_after" && "$char_after" < "$map_after" ]]; then
  pass "they came back in rAthena's order: login, then char, then map"
else
  fail "they came back out of order: login $login_after, char $char_after, map $map_after"
fi

# What each server holds to port 3306, read from the kernel's own table in
# its network namespace: 01 is ESTABLISHED, 08 is CLOSE_WAIT, the state a
# socket sits in after the server on the other end went away.
sleep 15
live=0; stale=0
for c in ra-login ra-char ra-map; do
  states="$(docker exec "$c" cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk '$3 ~ /:0CEA$/ {print $4}')"
  l="$(grep -c '^01$' <<<"$states")"; s="$(grep -c '^08$' <<<"$states")"
  echo "  $c: $l live, $s stale connections to the database"
  live=$((live + l)); stale=$((stale + s))
done
if [ "$stale" -eq 0 ]; then pass "no server holds a socket to the old database"; else fail "$stale sockets still point at the old database (CLOSE_WAIT)"; fi
if [ "$live" -ge 1 ]; then pass "the servers are connected to the new database ($live live)"; else fail "no server is connected to the database at all"; fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
