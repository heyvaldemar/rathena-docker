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

docker exec -e A="$ACCT" -e P="$NEW" "${RA_DB_CONTAINER:-ra-db}" sh -c '
  mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" '"$RA_DB_NAME"' \
    -e "UPDATE login SET user_pass = MD5(\"$P\") WHERE userid = \"$A\";
        SELECT ROW_COUNT();"' | tail -1 | {
  read -r rows
  [ "${rows:-0}" -ge 1 ] || { echo "FAILED: no account named $ACCT"; exit 1; }
  echo "   updated $rows row(s)"
}

mkdir -p secrets
install -m 600 /dev/null "$OUT"
printf '%s\n' "$NEW" > "$OUT"
echo "   new password written to $OUT (mode 600, not printed)"

# VERIFY BY LOGGING IN. A wrong hash and a right one look identical in the table,
# so the only honest check is to speak the login protocol and see what comes back.
echo "== verifying with a real login"
docker run --rm --network "container:${RA_LOGIN_CONTAINER:-ra-login}" -e A="$ACCT" -e P="$NEW" python:3.13-alpine python3 -c '
import os, socket, struct, time
a=os.environ["A"].encode(); p=os.environ["P"].encode()
s=socket.create_connection(("127.0.0.1",6900),timeout=8)
s.sendall(struct.pack("<HI",0x0064,${RA_PACKETVER:-20200401})+a.ljust(24,b"\0")+p.ljust(24,b"\0")+b"\x03")
time.sleep(0.7)
try: r=s.recv(512)
except Exception: r=b""
s.close()
ok = bool(r) and (r[0]==0x69 or struct.unpack_from("<H",r)[0]==0x0AC4)
print("   ACCEPTED" if ok else "   REFUSED")'
