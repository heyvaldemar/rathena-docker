#!/usr/bin/env bash
# Does tools/set-password.sh set a password the real login server accepts?
#
# The tool ends by logging in with the new password, because a wrong hash and
# a right one look the same in the table. From its first version until
# 2026-11 that check never ran: a shell ${...} inside the python's single
# quotes reached python as written, a SyntaxError, and the run stopped there.
# Nothing exercised it.
#
#   the tool     a scratch account, then the tool: exit 0, ACCEPTED, the file
#                mode 600 with one 16-character line
#   the control  the same login with a wrong password is refused, so an
#                ACCEPTED is the server telling the two apart
#   no account   an account that does not exist: exit 1, no file
#
# Needs the stack up and healthy (the build-and-test job leaves it so). The
# scratch account and its file are removed at the end.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

ACCT="setpw$$"
sql() { docker compose exec -T db sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot "$MARIADB_DATABASE" -N -e "$1"' _ "$1"; }
cleanup() {
  sql "DELETE FROM login WHERE userid = '$ACCT';" >/dev/null 2>&1
  rm -f "secrets/ro-$ACCT-password" "secrets/ro-$ACCT-password.new" "secrets/ro-nosuch$$-password" "secrets/ro-nosuch$$-password.new"
}
trap cleanup EXIT

# login <account> <password>: ACCEPTED or REFUSED, from the login server itself.
# The pair reaches the container by name (-e A -e P): as -e P="$2" the
# password was in docker's arguments, which every user on the runner reads
# with ps.
login() {
  A="$1" P="$2" docker run --rm --network container:ra-login -e A -e P python:3.13-alpine python3 -c '
import os, socket, struct, time
a=os.environ["A"].encode(); p=os.environ["P"].encode()
s=socket.create_connection(("127.0.0.1",6900),timeout=8)
s.sendall(struct.pack("<HI",0x0064,20200401)+a.ljust(24,b"\0")+p.ljust(24,b"\0")+b"\x03")
time.sleep(0.7)
try: r=s.recv(512)
except Exception: r=b""
s.close()
print("ACCEPTED" if r and (r[0]==0x69 or struct.unpack_from("<H",r)[0]==0x0AC4) else "REFUSED")'
}

sql "INSERT INTO login (userid, user_pass, sex, email) VALUES ('$ACCT', MD5('nobody-knows-this'), 'M', 'a@a.com');" \
  || { echo "cannot create the scratch account"; exit 1; }

echo "== the tool"
out=$(tools/set-password.sh "$ACCT" 2>&1); rc=$?
f="secrets/ro-$ACCT-password"
if [ "$rc" = 0 ] && grep -q "ACCEPTED" <<<"$out"; then pass "the new password: exit 0, the login server accepts it"; else fail "the tool: exit $rc, said: $out"; fi
if [ -f "$f" ] && [ "$(stat -c %a "$f")" = 600 ] && [ "$(wc -l <"$f")" = 1 ] && [ "$(tr -d '\n' <"$f" | wc -c)" = 16 ]; then pass "the file: mode 600, one 16-character line"; else fail "the file: $(ls -l "$f" 2>&1)"; fi
[ ! -e "$f.new" ] && pass "nothing left in $f.new" || fail "$f.new left behind"
if [ -f "$f" ] && [ "$(login "$ACCT" "$(cat "$f")")" = ACCEPTED ]; then pass "the file's password logs in, asked again from here"; else fail "the file's password does not log in"; fi

echo "== the control"
if [ "$(login "$ACCT" "not-the-password")" = REFUSED ]; then pass "a wrong password is refused"; else fail "a wrong password was not refused: ACCEPTED proves nothing"; fi

echo "== no account"
out=$(tools/set-password.sh "nosuch$$" 2>&1); rc=$?
if [ "$rc" = 1 ] && grep -q "no account named nosuch$$" <<<"$out" && [ ! -e "secrets/ro-nosuch$$-password" ] && [ ! -e "secrets/ro-nosuch$$-password.new" ]; then pass "an account that does not exist: exit 1, no file"; else fail "no account: exit $rc, said: $out"; fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
