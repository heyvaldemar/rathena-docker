#!/bin/bash
# render-conf.sh — build rAthena's conf/import/* from .env.
#
# WHY A GENERATOR. rAthena configuration files have no variable substitution, so
# the database password, the inter-server credentials and the public address would
# otherwise be typed into several files by hand and drift from .env the first time
# one of them changed. Here .env is the single source and these files are output.
#
# WHY conf/import AND NOT THE SHIPPED FILES. rAthena reads conf/*.conf and then
# overlays conf/import/*.txt. Editing the shipped files means every image rebuild
# overwrites your settings; the import directory is the documented way in and
# survives untouched.
#
# The generated files carry secrets, so they are 600 and git-ignored — the same
# treatment as left4dead2/server.cfg and jediacademy/cfg/server.cfg, which hold rcon
# passwords. They ARE in the restic stacks-config snapshot, and they can be rebuilt
# from .env at any time by running this script.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a
umask 077
mkdir -p conf-import

# --- database, used by login, char and map -----------------------------------
# ${RA_DB_HOST} is the compose service name — `db` — not an address. The database
# publishes no port, so it is reachable on this network and nowhere else; rAthena's
# own tools/docker/ publishes 3306 to the host with a hardcoded password, which is
# the thing this avoids.
cat > conf-import/inter_conf.txt <<EOF
login_server_ip: ${RA_DB_HOST}
login_server_port: 3306
login_server_id: ${RA_DB_USER}
login_server_pw: ${RA_DB_PASSWORD}
login_server_db: ${RA_DB_NAME}

ipban_db_ip: ${RA_DB_HOST}
ipban_db_port: 3306
ipban_db_id: ${RA_DB_USER}
ipban_db_pw: ${RA_DB_PASSWORD}
ipban_db_db: ${RA_DB_NAME}

char_server_ip: ${RA_DB_HOST}
char_server_port: 3306
char_server_id: ${RA_DB_USER}
char_server_pw: ${RA_DB_PASSWORD}
char_server_db: ${RA_DB_NAME}

map_server_ip: ${RA_DB_HOST}
map_server_port: 3306
map_server_id: ${RA_DB_USER}
map_server_pw: ${RA_DB_PASSWORD}
map_server_db: ${RA_DB_NAME}

web_server_ip: ${RA_DB_HOST}
web_server_port: 3306
web_server_id: ${RA_DB_USER}
web_server_pw: ${RA_DB_PASSWORD}
web_server_db: ${RA_DB_NAME}

# THE LOG DATABASE IS A SEPARATE SET OF KEYS. Missing these was the first failure
# here: every other credential was overridden, the login server still reported
# "Access denied for user 'ragnarok'" and the only clue was the file named in the
# debug line — loginlog.cpp. It was falling back to the shipped default password,
# which happens to use the same USERNAME as ours, so the error looked like a wrong
# password on a connection that was in fact a different connection entirely.
log_db_ip: ${RA_DB_HOST}
log_db_port: 3306
log_db_id: ${RA_DB_USER}
log_db_pw: ${RA_DB_PASSWORD}
log_db_db: ${RA_DB_NAME}
EOF

# --- char server --------------------------------------------------------------
# char_ip is what the LOGIN server hands to the client as "now go here". Ragnarok
# carries a 32-bit address in that packet, so it must be numeric: a hostname is
# accepted by the config parser and then quietly breaks the hand-off, leaving the
# client stuck after account login with nothing in the log.
#
# ⚠ KEEP RA_INTER_PASS AT 23 CHARACTERS OR FEWER. The inter-server credential is
# read into a fixed 24-byte buffer, so a longer password is silently truncated on
# the server side while the database keeps the whole thing — and the login server
# reports only "Invalid password" for an account whose name it just echoed back
# correctly. Measured 2026-08-07: a 24-character password was refused, its first
# 23 characters were accepted. .env now generates 20.
cat > conf-import/char_conf.txt <<EOF
server_name: ${RA_SERVER_NAME}
userid: ${RA_INTER_USER}
passwd: ${RA_INTER_PASS}
login_ip: ${RA_LOGIN_HOST}
char_ip: ${RA_PUBLIC_IP}

# PIN CODE OFF. rAthena ships it on, so the first thing a new player meets after
# the character screen is an undated dialog demanding a four-digit code entered by
# clicking a shuffled on-screen keypad — with no explanation of what it is or
# whether it is required. It is a second password for an account that already has
# one, designed for shards with item trading and account theft. Here it is pure
# obstruction: the owner hit it on the first login and could not tell what to press.
pincode_enabled: no
EOF

# --- map server ---------------------------------------------------------------
cat > conf-import/map_conf.txt <<EOF
userid: ${RA_INTER_USER}
passwd: ${RA_INTER_PASS}
char_ip: ${RA_CHAR_HOST}
map_ip: ${RA_PUBLIC_IP}
EOF

# --- rates --------------------------------------------------------------------
# Percent, so 2000 = 20x. Chosen for a SMALL server: classic 1x rates work on
# shards with thousands of players, where levelling is a party activity and the
# world is full. With a handful of friends the same rates are not nostalgia, just
# a slow solo grind nobody finishes.
#
# Cards stay at 100 (1x), boss cards too. That is the standard mid-rate shape:
# gear should flow, MVP cards should stay rare, or there is nothing left to want
# after the first week.
cat > conf-import/battle_conf.txt <<EOF
base_exp_rate: ${RA_BASE_EXP_RATE}
job_exp_rate: ${RA_JOB_EXP_RATE}

item_rate_common: ${RA_DROP_RATE}
item_rate_common_boss: ${RA_DROP_RATE}
item_rate_heal: ${RA_DROP_RATE}
item_rate_heal_boss: ${RA_DROP_RATE}
item_rate_use: ${RA_DROP_RATE}
item_rate_use_boss: ${RA_DROP_RATE}
item_rate_equip: ${RA_DROP_RATE}
item_rate_equip_boss: ${RA_DROP_RATE}

item_rate_card: ${RA_CARD_RATE}
item_rate_card_boss: ${RA_CARD_RATE}
item_rate_mvp: ${RA_CARD_RATE}
EOF

chmod 600 conf-import/*.txt
echo "rendered $(ls conf-import | wc -l) files into conf-import/ from .env"

# rAthena looks for these two optional imports and logs an Error when they are
# absent. They are legitimately empty here — but an error line that is always
# present is an error line nobody reads, and the next real one hides behind it.
for f in packet_conf script_conf log_conf; do : > "conf-import/$f.txt"; done

# inter_server.yml is the same story with a different extension: char-server logs
# "Failed to open INTER_SERVER_DB database file" on every start without it. It is
# a YAML database, not a flat config, so an empty file will not do — the parser
# wants a header before it will accept the file as legitimately empty.
# THE YAML IMPORTS NEED A HEADER, NOT JUST EXISTENCE. rAthena's YAML loader
# reports "Failed to open <TYPE> database file" for a missing import on every
# start, and these are legitimately empty for us — we override nothing. An error
# line that is always there is an error line nobody reads, and the next real one
# hides behind it.
#
# They surface ONE AT A TIME as each earlier one is fixed, so chasing them
# individually takes as many restarts as there are files. The full set comes from
# grepping the shipped conf/ and db/ for conf/import/*.yml references.
for db in inter_server:INTER_SERVER_DB groups:PLAYER_GROUP_DB atcommands:ATCOMMAND_DB; do
  cat > "conf-import/${db%%:*}.yml" <<YML
Header:
  Type: ${db##*:}
  Version: 1
Body: []
YML
done

# Plain-text imports only have to exist.
for f in msg_conf web_conf; do : > "conf-import/$f.txt"; done
chmod 600 conf-import/*.yml conf-import/*.txt

# --- login server ---------------------------------------------------------------
# SELF-REGISTRATION ON. rAthena ships new_account: no, so without this the first
# person to try gets "account does not exist" and there is no way to make one — the
# card on the status page said accounts are created on first login, which would have
# been a lie. Registration happens by appending _M or _F to the password ONCE, which
# is the classic Ragnarok convention and the thing every newcomer trips over.
#
# Open registration is deliberate: this shard is reachable from the internet like the
# Source servers, and the private Minecraft worlds are the ones behind a whitelist.
#
# PASSWORDS ARE HASHED. rAthena ships use_MD5_passwords: no, which stores account
# passwords as PLAIN TEXT — readable by anyone who reaches the database, and
# people reuse passwords, so the damage of a leak would not stop at this game.
# Verified 2026-08-08 by reading the table: the owner's password was sitting
# there in the clear.
#
# MD5 is weak by modern standards. It is not a considered choice — it is the only
# hashing rAthena implements. It is still the difference between "an attacker has
# every password" and "an attacker has hashes".
#
# WHAT IT COSTS: src/login/loginclif.cpp rejects client-side password encryption
# outright when this is on (logclif_auth_failed(&sd, 3)). The two are mutually
# exclusive by design — the challenge-response mode computes md5(session_key +
# stored_password) and therefore needs the stored password in the clear. So this
# protects the database at the cost of the password crossing the network
# unencrypted. Ragnarok has no TLS either way; the database is the likelier leak.
#
# MIGRATION: the hash is applied to what the CLIENT sends (loginclif.cpp:279),
# including the char-server's own inter-server login (line 411). Existing rows
# were converted in place with UPDATE login SET user_pass = MD5(user_pass) —
# nobody had to re-register, because md5 of the stored plaintext is exactly what
# the server will now compare against.
#
# DNSBL ON, WITH A LIST WE CHECKED OURSELVES. rAthena ships
# "bl.blocklist.de, socks.dnsbl.sorbs.net" and SORBS SHUT DOWN IN 2024 — its zone
# answers NXDOMAIN, so every single login would pay for a DNS lookup that can
# never match. Verified 2026-08-08 against the control address 127.0.0.2, which
# every working blocklist answers by convention:
#   bl.blocklist.de       -> 127.0.0.2         alive (SSH/FTP/IMAP attackers)
#   socks.dnsbl.sorbs.net -> NXDOMAIN          dead
#   dnsbl.dronebl.org     -> 127.0.0.1         alive (proxies, drones, botnets)
#   zen.spamhaus.org      -> 127.255.255.254   refuses public resolvers
# So: drop the dead one, keep the live one, add DroneBL because open proxies are
# what actually shows up on a game server.
cat > conf-import/login_conf.txt <<EOF
new_account: yes
new_acc_length_limit: yes
use_MD5_passwords: yes
use_dnsbl: yes
dnsbl_servers: bl.blocklist.de, dnsbl.dronebl.org
EOF
chmod 600 conf-import/*.txt
