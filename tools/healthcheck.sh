#!/bin/sh
# healthcheck.sh - healthy only when the rAthena server itself answers.
#
# Run by Docker inside each server's container (the compose file mounts it
# read-only). Each server is asked something a game client asks it, and only
# the server's own reply counts:
#
#   healthcheck.sh login [port]   the password-hash key a client requests before
#                                 it logs in (CA_REQ_HASH, 0x01db): the
#                                 login-server answers AC_ACK_HASH, 0x01dc
#   healthcheck.sh char [port]    a client's connect (0x0065) for account
#                                 1234567, which the char-server answers by
#                                 echoing the account id before anything else.
#                                 rAthena hands out accounts from 2000000, so
#                                 that one is never real; the login-server is
#                                 asked about it and refuses it
#   healthcheck.sh map [port]     a client's CZ_ENTER (0x0436) for account 0,
#                                 which the map-server refuses with 0x006a. It
#                                 is sent as 23 bytes, the longest form any
#                                 PACKETVER uses, and refused for its length or
#                                 its account either way
#
# NOT THE PORT. Up to v1.6.1 each check was `netstat -ltn | grep -q :<port>`.
# A stopped or hung server keeps its listening socket, and the kernel accepts
# connections into its backlog for it; CI stops each server with SIGSTOP and
# requires this check red while that one stays green.
#
# NOT THE LOG, and it writes to the log. Each check leaves its server a line
# or two: "Closed connection from '127.0.0.1'" on the login-server; "request
# connect - account_id:1234567" on the char-server and, on the login-server,
# that account's authentication REFUSED; "unknown connect packet 0x0436" on
# the map-server. That is why the compose file checks every 60 seconds.
#
# WITHIN DOCKER'S TIMEOUT. nc is cut off after 3 seconds.
#
# INSIDE THE CONTAINER. Healthy proves the server answers on 127.0.0.1 in its
# own container. It does not prove the ports are published on the host, nor
# that a firewall lets players in, nor that the address the char-server tells
# clients (RA_PUBLIC_IP) is one they can reach, nor that the servers have
# logged in to each other (CI checks that with tools/set-inter-account.sh).
#
# busybox only, as the image has it: printf (octal escapes), nc, timeout,
# head, od, tr.
set -u
role=${1:-}
case $role in
  login)
    port=${2:-6900}
    req='\333\001'
    want=dc01 ;;
  char)
    port=${2:-6121}
    req='\145\000\207\326\022\000\001\000\000\000\002\000\000\000\000\000\000'
    want=87d61200 ;;
  map)
    port=${2:-5121}
    req='\066\004'
    i=0
    while [ "$i" -lt 21 ]; do req="$req\\000"; i=$((i + 1)); done
    want=6a00 ;;
  *)
    echo "usage: healthcheck.sh login|char|map [port]" >&2
    exit 2 ;;
esac
n=$(( ${#want} / 2 ))
# shellcheck disable=SC2059   # the request is a printf format on purpose: octal escapes
r=$(exec 2>/dev/null; printf "$req" | timeout 3 nc 127.0.0.1 "$port" | head -c "$n" | od -An -v -tx1 | tr -d ' \n')
if [ "$r" = "$want" ]; then
  echo "healthy: the $role-server answered on 127.0.0.1:$port"
  exit 0
fi
echo "unhealthy: the $role-server gave no answer on 127.0.0.1:$port${r:+ (got $r)}" >&2
exit 1
