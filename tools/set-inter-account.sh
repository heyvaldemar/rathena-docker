#!/bin/bash
# set-inter-account.sh: give the inter-server account the credentials in .env.
#
# WHY THIS EXISTS. The schema (main.sql) creates the account the char-server
# logs in to the login-server with: account_id 1, sex S, s1 / p1.
# render-conf.sh tells char and map to log in as RA_INTER_USER /
# RA_INTER_PASS instead. Until that row matches, the login-server answers
# "Unknown account" and refuses the char-server, and every player whose
# password is right is then turned away with "there is no char-server online".
# Every container still reports healthy: the healthchecks look at listening
# ports. This step was missing from the README's first start, and CI ran
# without it for months.
#
# WHAT IT DOES. One UPDATE of account 1. The password is stored as md5, as
# use_MD5_passwords requires (render-conf.sh), computed here; both values go to
# the database in the environment, never on a command line. If the char-server
# is running, the script then waits for the login-server to accept it.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
# shellcheck source=/dev/null
. ./.env
set +a

U=${RA_INTER_USER:?RA_INTER_USER is not set in .env}
P=${RA_INTER_PASS:?RA_INTER_PASS is not set in .env}
case "$U" in *[!A-Za-z0-9_]*) echo "RA_INTER_USER may hold letters, digits and _ only" >&2; exit 1 ;; esac
if [ ${#U} -lt 4 ] || [ ${#U} -gt 23 ]; then echo "RA_INTER_USER must be 4 to 23 characters" >&2; exit 1; fi
# 23 is the server's buffer, not a preference (README: "Invalid password for
# the inter-server account").
if [ ${#P} -gt 23 ]; then echo "RA_INTER_PASS is longer than 23 characters, and the servers would cut it" >&2; exit 1; fi
H=$(printf '%s' "$P" | openssl dgst -md5 -r | cut -c1-32)
case "$H" in *[!0-9a-f]*|'') echo "could not hash RA_INTER_PASS" >&2; exit 1 ;; esac

DB=${RA_DB_CONTAINER:-ra-db}
# The statement goes to mariadb on stdin and the root password in MYSQL_PWD:
# an argument is on a command line every user on the host can list.
n=$(U="$U" H="$H" D="$RA_DB_NAME" docker exec -e U -e H -e D "$DB" sh -c '
  printf "UPDATE login SET userid = \"%s\", user_pass = \"%s\" WHERE account_id = 1 AND sex = \"S\";\nSELECT COUNT(*) FROM login WHERE account_id = 1 AND sex = \"S\" AND userid = \"%s\" AND user_pass = \"%s\";\n" "$U" "$H" "$U" "$H" |
    MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot "$D" -N' | tail -1)
if [ "$n" != 1 ]; then
  echo "FAILED: there is no inter-server account (account_id 1, sex S) to update: load sql-files/main.sql first" >&2
  exit 1
fi
echo "   account 1 is now $U, with the password from .env (stored as md5, not printed)"

CHAR=${RA_CHAR_CONTAINER:-ra-char}
LOGIN=${RA_LOGIN_CONTAINER:-ra-login}
if [ "$(docker inspect -f '{{.State.Running}}' "$CHAR" 2>/dev/null)" != true ]; then
  echo "   $CHAR is not running; it logs in on its next start"
  exit 0
fi
# The char-server retries its login by itself; the newest verdict on it in the
# login-server's log is the one in force.
for _ in $(seq 1 30); do
  latest=$(docker logs "$LOGIN" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep "Connection of the char-server '" | tail -1) || true
  case "$latest" in
    *accepted*) echo "   the login-server accepted the char-server"; exit 0 ;;
  esac
  sleep 2
done
echo "FAILED: the account is updated, but the login-server has not accepted the char-server within 60 s: docker logs $LOGIN" >&2
exit 1
