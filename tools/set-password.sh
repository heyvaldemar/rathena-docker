#!/bin/bash
# set-password.sh <account> — set a Ragnarok account password from the host.
#
# WHY THIS EXISTS. Ragnarok has no in-game password command — all 314 registered
# atcommands were checked, and there is `accinfo` and `changesex` and nothing for
# a password. The web page at webpw/ covers the normal case, but it needs the
# CURRENT password, which is no help when nobody knows it any more.
#
# It also covers the case where the page itself misled someone: an early version
# carried maxlength on its inputs, so a thirty-character password was silently
# cut to twenty-three and accepted, leaving its owner holding a password he had
# never chosen and could not reconstruct.
#
# WHAT IT DOES. rAthena stores md5 hex in login.user_pass once
# use_MD5_passwords is on, so setting a password is one UPDATE. The value is
# parameterised through the client rather than interpolated into SQL — the same
# discipline the web page follows, for the same reason.
#
# The new password is written to a mode-600 file and never printed: a password
# echoed to a terminal lives on in scrollback, in shell history, and in
# screenshots.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
# shellcheck source=/dev/null
. ./.env
set +a

ACCT=${1:?usage: set-password.sh <account>}
OUT=secrets/ro-$ACCT-password

# 23 IS RATHENA'S CEILING, not a preference: src/login/login.hpp declares
# passwd[23+1] for plaintext, so a longer password is one the game client cannot
# send. 16 leaves room and is still far past anything guessable.
#
# NOT `tr -dc ... | head -c`: head closes the pipe, tr dies of SIGPIPE, and with
# pipefail that becomes a silent exit under set -e.
NEW=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)

# THE NEW PASSWORD IS WRITTEN DOWN BEFORE THE DATABASE SEES IT. An exec cut off
# by a restart ends with 137 and prints nothing (measured on Docker 29.7.2),
# and it can be cut off after the UPDATE ran: the account then has a password
# whose only copy is in this script's memory. Written down only after the
# database's answer, it ended "FAILED: no account" and was gone. So the new
# password waits in $OUT.new, beside any earlier $OUT, until the database or
# a real login says which one is in effect.
mkdir -p secrets
install -m 600 /dev/null "$OUT.new"
printf '%s\n' "$NEW" > "$OUT.new"

# 128 and below: the exec never got as far as the UPDATE (Docker refusing, as
# "cannot exec in a stopped state" with 128, printed on stdout, or the
# database refusing it). Above 128: killed by a signal, maybe after it ran.
# A and P reach docker in the environment, and the statement reaches mariadb
# on stdin from the shell's own printf: neither the new password nor the root
# one is on a command line anyone on the host can list (-e "<sql>" would put
# the statement, password and all, in mariadb's arguments).
if res=$(A="$ACCT" P="$NEW" docker exec -e A -e P "${RA_DB_CONTAINER:-ra-db}" sh -c '
  printf "UPDATE login SET user_pass = MD5(\"%s\") WHERE userid = \"%s\";\nSELECT ROW_COUNT();\n" "$P" "$A" |
    MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot '"$RA_DB_NAME"); then
  rows=$(printf '%s\n' "$res" | tail -1)
else
  rc=$?
  if [ "$rc" -le 128 ]; then
    rm -f "$OUT.new"
    echo "FAILED: the UPDATE did not run (docker exec ended with $rc${res:+: $res}); nothing was changed"
    exit 1
  fi
  rows="?"
  echo "   the database's answer was lost: docker exec was killed (exit $rc), maybe after the UPDATE ran"
fi
case "$rows" in
  0) rm -f "$OUT.new"; echo "FAILED: no account named $ACCT"; exit 1 ;;
  ''|*[!0-9]*) echo "   the new password stays in $OUT.new until a login proves it; $OUT, if there is one, is left as it was" ;;
  *) mv -f "$OUT.new" "$OUT"
     echo "   updated $rows row(s)"
     echo "   new password written to $OUT (mode 600, not printed)" ;;
esac

# VERIFY BY LOGGING IN. A wrong hash and a right one look identical in the table,
# so the only honest check is to speak the login protocol and see what comes back.
# The packet version travels as V: inside these single quotes, a shell
# ${...} reaches python as it is written, and until 2026-11 this check was a
# SyntaxError that ended the run before it said anything.
#
# THE ANSWER IS READ BY ITS PACKET. 0x0069 or 0x0AC4 is a login accepted.
# 0x0081 comes only after the password was accepted (loginclif.cpp: it is sent
# from logclif_auth_ok, which runs when login_mmo_auth succeeds), and code 1
# there is the server refusing to go on, most often because no char-server is
# online: the password is proven all the same. A wrong password is
# AC_REFUSE_LOGIN, 0x006A or 0x083E.
echo "== verifying with a real login"
verdict=$(A="$ACCT" P="$NEW" V="${RA_PACKETVER:-20200401}" docker run --rm --network "container:${RA_LOGIN_CONTAINER:-ra-login}" -e A -e P -e V python:3.13-alpine python3 -c '
import os, socket, struct, time
a=os.environ["A"].encode(); p=os.environ["P"].encode()
s=socket.create_connection(("127.0.0.1",6900),timeout=8)
s.sendall(struct.pack("<HI",0x0064,int(os.environ["V"]))+a.ljust(24,b"\0")+p.ljust(24,b"\0")+b"\x03")
time.sleep(0.7)
try: r=s.recv(512)
except Exception: r=b""
s.close()
h = struct.unpack_from("<H", r)[0] if len(r) >= 2 else -1
if h in (0x0069, 0x0AC4):
    print("   ACCEPTED")
elif h == 0x0081:
    print("   ACCEPTED, then the server stopped the login (code %d; 1 is most often no char-server online)" % (r[2] if len(r) > 2 else -1))
else:
    print("   REFUSED")') || verdict="   NO ANSWER: the login check did not complete"
echo "$verdict"
if [ "${verdict#   ACCEPTED}" = "$verdict" ]; then
  [ ! -e "$OUT.new" ] || echo "   not proven: the new password stays in $OUT.new, and $OUT, if there is one, is left as it was"
  exit 1
fi
if [ -e "$OUT.new" ]; then
  mv -f "$OUT.new" "$OUT"
  echo "   the login proves it: new password moved to $OUT (mode 600, not printed)"
fi
exit 0
