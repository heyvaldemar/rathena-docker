# ALPINE, DELIBERATELY, AND THE SAME TAG THE OTHER WATCHERS USE. PyMySQL is pure
# Python, so nothing needs a compiler here — the reason an earlier script on this
# host had to reach for the Debian image (argon2-cffi) does not apply.
#
# Sharing python:3.13-alpine with the six watchers is the point: diun watches
# that exact tag, so this image's base is covered by an entry that already
# exists. Built on 3.13-slim it was the one running service whose foundation
# nothing was watching — and it is the only one facing the internet with a
# database connection.
#
# Pinned by digest since 2026-11-08, like every other base here: the freshness
# check compares it with what the tag names now, and fleet triage moves it when
# the tag is repushed with the same Python inside. A new Python patch changes
# PYTHON_VERSION in the image, and that is left to a person.
FROM python:3.13-alpine@sha256:1e1f6334529d1fb26a2ef619d7cffb30a7c7d7cc1cc7338ebee283a58d1aeaca

RUN pip install --no-cache-dir "PyMySQL==1.1.1" \
 && adduser -S -u 1001 -s /sbin/nologin webpw

COPY app.py /app/app.py
USER webpw
EXPOSE 8090
ENTRYPOINT ["python3", "/app/app.py"]
