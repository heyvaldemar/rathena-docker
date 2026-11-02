#!/usr/bin/env bash
# Does tools/set-password.sh keep the new password whenever it may be in
# effect, and say what happened when Docker fails under it?
#
# The UPDATE runs through docker exec, and Docker can fail in the middle.
# Measured on Docker 29.7.2 against a container restarted under a loop of
# execs: "cannot exec in a stopped state" printed on STDOUT with exit 128,
# and an exec killed by the restart ending with 137 and nothing printed. The
# first never reached the database. The second can come after the UPDATE
# ran, and the script used to answer it "FAILED: no account" and keep no
# copy of the password it had just set.
#
# A fake `docker` early in PATH plays the database, which remembers the last
# password it was given. The login check's own python runs for real, against
# a stand-in login server on 127.0.0.1:6900 that answers as loginclif.cpp
# does: 0x0AC4 for the password in the database, 0x0081 code 1 for that
# password when no char-server is online, 0x083E code 1 for any other. That
# python was a SyntaxError from the first version until 2026-11. The script
# runs from a scratch copy of the repository, so nothing under secrets/ here
# is touched. tests/e2e-set-password.sh does the same against the real stack.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

T=$(mktemp -d)
mkdir -p "$T/repo/tools" "$T/bin"
cp "$ROOT/tools/set-password.sh" "$T/repo/tools/"
printf 'RA_DB_NAME=ragnarok\n' > "$T/repo/.env"
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
# A and P arrive in the environment, as set-password.sh passes them.
case "$1" in
  exec)
    case "$FAKE_DB" in
      ok)      printf '%s\n' "$P" > "$STATE/db"; printf 'ROW_COUNT()\n1\n'; exit 0 ;;
      none)    printf 'ROW_COUNT()\n0\n'; exit 0 ;;
      refused) echo "Error response from daemon: container ra-db is not running" >&2; exit 1 ;;
      stopped) echo "cannot exec in a stopped state"; exit 128 ;;
      after)   printf '%s\n' "$P" > "$STATE/db"; exit 137 ;;   # killed after the UPDATE ran
      before)  exit 137 ;;                                     # killed before it did
    esac ;;
  run)
    prog=""; prev=""
    for a in "$@"; do [ "$prev" = -c ] && prog=$a; prev=$a; done
    exec python3 -c "$prog" ;;
esac
exit 99
SH
chmod +x "$T/bin/docker"

OUT="$T/repo/secrets/ro-someone-password"
# The stand-in login server: one 55-byte CA_LOGIN per connection.
mkdir -p "$T/state"
echo old > "$T/state/db"; echo ok > "$T/state/login"
STATE="$T/state" python3 -c '
import os, socket
st = os.environ["STATE"]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 6900)); srv.listen(8)
while True:
    c, _ = srv.accept()
    try:
        d = b""
        while len(d) < 55:
            b = c.recv(55 - len(d))
            if not b: break
            d += b
        if len(d) < 55: continue          # the readiness probe below
        want = open(os.path.join(st, "db")).read().strip().encode()
        mode = open(os.path.join(st, "login")).read().strip()
        if d[30:54].rstrip(b"\0") != want:
            c.sendall(b"\x3e\x08\x01\x00\x00\x00" + b"\0" * 20)
        elif mode == "nochar":
            c.sendall(b"\x81\x00\x01")
        else:
            c.sendall(b"\xc4\x0a" + b"\0" * 62)
    except OSError:
        pass
    finally:
        c.close()
' &
LOGIN_PID=$!
disown "$LOGIN_PID" 2>/dev/null || true
trap 'kill "$LOGIN_PID" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do python3 -c 'import socket; socket.create_connection(("127.0.0.1", 6900), timeout=1).close()' 2>/dev/null && break; sleep 0.1; done

# run <db> [login]: one run from a fresh state; the database holds "old", and
# so does $OUT, as after an earlier successful run. Sets $out and $rc.
run() {
  rm -rf "$T/repo/secrets"; mkdir -p "$T/repo/secrets"
  echo old > "$T/state/db"; echo old > "$OUT"; echo "${2:-ok}" > "$T/state/login"
  out=$(PATH="$T/bin:$PATH" STATE="$T/state" FAKE_DB="$1" "$T/repo/tools/set-password.sh" someone 2>&1); rc=$?
}
held() { cat "$OUT" 2>/dev/null; }
in_db() { cat "$T/state/db"; }

echo "== the database answers"
run ok
[ "$rc" = 0 ] && grep -q ACCEPTED <<<"$out" && [ "$(held)" = "$(in_db)" ] && [ ! -e "$OUT.new" ] \
  && pass "updated and accepted: exit 0, the file holds the password in effect" || fail "ok: exit $rc, said: $out"
[ "$(stat -c %a "$OUT" 2>/dev/null || stat -f %Lp "$OUT")" = 600 ] && pass "the file is mode 600" || fail "the file is mode $(stat -c %a "$OUT" 2>/dev/null || stat -f %Lp "$OUT")"
run ok nochar
[ "$rc" = 0 ] && grep -q "ACCEPTED, then the server stopped the login (code 1" <<<"$out" && [ "$(held)" = "$(in_db)" ] \
  && pass "accepted, then stopped for want of a char-server: the password is proven, exit 0" || fail "nochar: exit $rc, said: $out"
run none
[ "$rc" = 1 ] && grep -q "no account named someone" <<<"$out" && [ "$(held)" = old ] && [ ! -e "$OUT.new" ] \
  && pass "no such account: exit 1, the earlier file untouched, nothing left over" || fail "none: exit $rc, said: $out"

echo "== Docker fails before the UPDATE"
for f in refused stopped; do
  run $f
  [ "$rc" = 1 ] && grep -q "the UPDATE did not run" <<<"$out" && [ "$(held)" = old ] && [ ! -e "$OUT.new" ] \
    && pass "$f: exit 1, says the UPDATE did not run, nothing changed" || fail "$f: exit $rc, said: $out"
done

echo "== Docker kills the exec, and nobody knows whether the UPDATE ran"
run after
[ "$rc" = 0 ] && grep -q ACCEPTED <<<"$out" && [ "$(held)" = "$(in_db)" ] && [ ! -e "$OUT.new" ] \
  && pass "killed after the UPDATE: the login proves it, and the file holds it" || fail "after: exit $rc, file holds the password in effect: $([ "$(held)" = "$(in_db)" ] && echo yes || echo no), said: $out"
run before
[ "$rc" = 1 ] && grep -q REFUSED <<<"$out" && [ "$(held)" = old ] && [ "$(in_db)" = old ] && [ -s "$OUT.new" ] \
  && pass "killed before the UPDATE: not proven, exit 1, the earlier file untouched, the new one kept apart" || fail "before: exit $rc, said: $out"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
