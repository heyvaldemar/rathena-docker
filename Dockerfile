# rAthena — Ragnarok Online server emulator, built PRE-RENEWAL.
#
# WHY WE BUILD OUR OWN. rAthena publishes images on Docker Hub (rathena/rathena-prere
# and friends) but they were last rebuilt 2025-12-02 while the source is committed to
# weekly — eight months of drift on a server that has no versioning of its own. And
# the project's own tools/docker/ is a DEVELOPMENT setup, not a deployment: its
# Dockerfile is alpine plus gcc, gdb and valgrind with an empty ENTRYPOINT, its
# compose mounts the whole git checkout into every container and builds in place, and
# it hardcodes the database password as "ragnarok" while publishing 3306 to the host.
# None of that belongs on a machine facing the internet.
#
# So: build once here, ship only what runs.
#
# THE ERA IS COMPILED IN. --enable-prere selects pre-renewal; renewal is the default
# and you cannot switch afterwards without rebuilding. Pre-renewal is what the
# private-server population actually plays — roughly two to one by concurrent players
# in August 2026, and the largest single shard on the scene is pre-renewal.
#
# PACKETVER MUST MATCH THE CLIENT. It is a compile-time constant naming the client
# build players connect with. Get it wrong and clients disconnect at character
# select with nothing useful in the log. It is an ARG so changing it is a rebuild,
# not an edit of a running server.

ARG ALPINE=3.24

# ---------------------------------------------------------------- build ----
FROM alpine:${ALPINE} AS build

# Same toolchain the project uses, minus the debuggers: this stage is thrown away.
RUN apk add --no-cache git make gcc g++ zlib-dev mariadb-dev linux-headers bash

# FULL SHA, not an abbreviation: `git fetch --depth 1 origin <ref>` will not resolve
# a shortened hash — the remote has to be asked for an object it can name exactly.
# The first build here failed on `2fe6ab3dc4d8` for precisely that reason.
ARG RATHENA_REF=e985006171d2eb320ee512a653f4c83aea3d81b6
# PACKETVER must match the client your players use. rAthena's own default is
# 20211103, which it classifies as PACKETVER_RE — the Sakray branch. 20200401
# falls under PACKETVER_MAIN and suits a pre-renewal shard; it is what the
# widely-linked pre-renewal client pack speaks. See src/config/packets.hpp for
# the ranges, and change this to match whatever client you actually hand out.
ARG PACKETVER=20200401

# Shallow clone of one commit: rAthena has no releases, only a rolling master, so
# "the version" IS the commit. Pinning it is the difference between a rebuild that
# reproduces this server and one that produces a different one.
WORKDIR /src
RUN git init -q . \
 && git remote add origin https://github.com/rathena/rathena.git \
 && git fetch -q --depth 1 origin "${RATHENA_REF}" \
 && git checkout -q FETCH_HEAD \
 && git rev-parse HEAD > /src/BUILT_FROM

RUN ./configure --enable-prere --enable-packetver=${PACKETVER} \
 && make server \
 && test -x login-server && test -x char-server && test -x map-server

# -------------------------------------------------------------- runtime ----
FROM alpine:${ALPINE}

# Runtime only. No compiler, no git, no shell tooling beyond what the server needs
# to start. `tini` because the three servers are long-lived foreground processes and
# something has to reap and forward signals properly.
RUN apk add --no-cache libstdc++ zlib mariadb-connector-c tini \
 && addgroup -g 1000 -S rathena \
 && adduser -u 1000 -S -G rathena -h /rathena rathena

WORKDIR /rathena

# The binaries, plus the data the map server reads at startup. conf/ is copied as
# shipped and overridden at runtime through conf/import/, which is how rAthena is
# designed to be configured — editing the shipped files means every rebuild fights
# your settings.
COPY --from=build --chown=rathena:rathena /src/login-server /src/char-server /src/map-server /rathena/
COPY --from=build --chown=rathena:rathena /src/conf /rathena/conf
COPY --from=build --chown=rathena:rathena /src/db   /rathena/db
COPY --from=build --chown=rathena:rathena /src/npc  /rathena/npc
COPY --from=build --chown=rathena:rathena /src/BUILT_FROM /rathena/BUILT_FROM

# sql-files are not needed by the servers themselves — the database container loads
# them once — but keeping them in the image means the schema always matches the
# binaries that will talk to it.
COPY --from=build --chown=rathena:rathena /src/sql-files /rathena/sql-files

USER rathena
ENTRYPOINT ["/sbin/tini", "--"]
