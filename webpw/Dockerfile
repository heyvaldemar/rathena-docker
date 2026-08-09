# ALPINE, DELIBERATELY, AND THE SAME TAG THE OTHER WATCHERS USE. PyMySQL is pure
# Python, so nothing needs a compiler here — the reason an earlier script on this
# host had to reach for the Debian image (argon2-cffi) does not apply.
#
# Sharing python:3.13-alpine with the six watchers is the point: diun watches
# that exact tag, so this image's base is covered by an entry that already
# exists. Built on 3.13-slim it was the one running service whose foundation
# nothing was watching — and it is the only one facing the internet with a
# database connection.
FROM python:3.13-alpine

RUN pip install --no-cache-dir "PyMySQL==1.1.1" \
 && adduser -S -u 1001 -s /sbin/nologin webpw

COPY app.py /app/app.py
USER webpw
EXPOSE 8090
ENTRYPOINT ["python3", "/app/app.py"]
