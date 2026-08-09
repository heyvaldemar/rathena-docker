#!/usr/bin/env python3
# Ragnarok password page — one form, one job.
#
# WHY NOT FluxCP. The obvious answer to "players cannot change their password" is
# rAthena's own control panel, and it was rejected on evidence rather than taste:
# an open security audit filed 2026-03-04 lists 8 vulnerabilities, 2 of them
# CRITICAL, including SQL injection in modules/servicedesk/staffview.php where a
# ticket id is interpolated straight into a query — the report's own words are
# "enables full database compromise". Five months, no reply. The project's last
# commit is 2025-11-03 and it has taken roughly thirty commits in two years.
#
# That is a large PHP application, publicly exposed, holding credentials to the
# account database, with known unfixed holes. This file is the alternative: it
# does one thing, it is short enough to read in a sitting, and every line of it
# is ours.
#
# WHAT IT DELIBERATELY CANNOT DO. There is no account listing, no registration,
# no ticket system, no admin view, no session, no cookie. The only state it
# changes is one column of one row, and only for someone who already proved they
# know the current password. An attacker who fully compromises this service gains
# what a player already has.
#
# WHERE IT RUNS. On the stack's own network, reaching the database by service
# name. The database publishes no port to the host, so widening this page's reach
# never widens the database's. Put a reverse proxy or tunnel in front: the page
# takes passwords and has no business on plain HTTP.
import hashlib, html, json, os, re, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

import pymysql

DB = dict(host=os.environ.get("RA_DB_HOST", "db"), port=3306,
          user=os.environ["RA_DB_USER"], password=os.environ["RA_DB_PASSWORD"],
          database=os.environ["RA_DB_NAME"], charset="utf8mb4",
          autocommit=False, connect_timeout=5)

MIN_LEN = int(os.environ.get("MIN_PASSWORD_LENGTH", "8"))
# rAthena's own limit: src/login/login.hpp declares passwd[23+1] for plaintext.
# Offering a longer one here would produce a password the game client cannot send.
MAX_LEN = 23

# Attempts are counted per address. The point is not to stop a determined
# attacker — they can hammer the game's login port directly — but to keep this
# form from being a *more convenient* oracle than the port, and to make a
# password-guessing run against one account expensive.
# Shown in the page title and heading, and as an optional link at the foot.
# Named after the shard rather than hardcoded so this file is identical on every
# server that runs it.
SHARD = os.environ.get("SHARD_NAME", "the server")
SITE = os.environ.get("SITE_URL", "")

RATE_MAX = int(os.environ.get("RATE_MAX", "5"))
RATE_WINDOW = int(os.environ.get("RATE_WINDOW_SECONDS", "900"))
_hits, _lock = {}, threading.Lock()

# THE ANSWER IS THE SAME FOR EVERY FAILURE. Distinguishing "no such account"
# from "wrong password" turns this page into an account-name oracle: an attacker
# learns which names exist before spending a single guess on a password. The
# server's own log records the real reason; the visitor gets one sentence.
WRONG = "That account name and password do not match anything here."

CSS = """
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
 background:#191122;color:#F2E9F5;font:16px/1.6 ui-sans-serif,system-ui,sans-serif;padding:1.5rem}
main{width:100%;max-width:26rem}
h1{font-size:1.35rem;margin:0 0 .35rem;font-weight:650}
p.sub{margin:0 0 1.6rem;color:#9C8AAE;font-size:.92rem}
label{display:block;margin:0 0 1rem}
span.l{display:block;font-size:.85rem;color:#9C8AAE;margin-bottom:.3rem}
input{width:100%;padding:.6rem .7rem;border-radius:.4rem;border:1px solid #3a2d47;
 background:#221733;color:#F2E9F5;font:inherit}
input:focus{outline:2px solid #E16B8C;outline-offset:1px;border-color:transparent}
button{width:100%;padding:.65rem;border:0;border-radius:.4rem;background:#E16B8C;
 color:#191122;font:inherit;font-weight:650;cursor:pointer}
button:hover{background:#F5B8D0}
.msg{padding:.7rem .8rem;border-radius:.4rem;margin:0 0 1.2rem;font-size:.92rem}
.err{background:rgba(208,119,112,.15);border-left:3px solid #D08770}
.ok{background:rgba(104,190,141,.15);border-left:3px solid #68BE8D}
span.hint{display:block;font-size:.78rem;color:#9C8AAE;margin:0 0 .4rem;line-height:1.45}
span.hint code{color:#F5B8D0}
footer{margin-top:1.8rem;padding-top:1rem;border-top:1px solid #2c2140;
 font-size:.82rem;color:#9C8AAE}
footer a{color:#E16B8C;text-decoration:none}
footer a:hover{text-decoration:underline}
"""

PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>%s — change your password</title><style>%s</style></head><body><main>
<h1>Change your %s password</h1>
<p class="sub">Ragnarok has no way to do this in the game, so it happens here.</p>
%s
<form method="post" autocomplete="off">
<label><span class="l">Account name</span>
 <span class="hint">The name you log in with — without the <code>_M</code> you added when
 you first signed up.</span>
 <input name="account" required autocapitalize="none" spellcheck="false"></label>
<label><span class="l">Current password</span><input name="old" type="password" required></label>
<label><span class="l">New password</span>
 <span class="hint">%d to %d characters. The upper limit is the game client's, not ours —
 it cannot send a longer one.</span>
 <input name="new" type="password" required></label>
<label><span class="l">New password again</span><input name="new2" type="password" required></label>
<button type="submit">Change it</button>
</form>
%s
</main></body></html>"""


def rate_ok(ip):
    now = time.time()
    with _lock:
        hits = [t for t in _hits.get(ip, []) if now - t < RATE_WINDOW]
        if len(hits) >= RATE_MAX:
            _hits[ip] = hits
            return False
        hits.append(now)
        _hits[ip] = hits
        return True


def change(account, old, new):
    """Returns (ok, message). Every failure returns the same text — see WRONG."""
    if not re.fullmatch(r"[A-Za-z0-9_]{4,23}", account):
        return False, WRONG
    if not (MIN_LEN <= len(new) <= MAX_LEN):
        return False, "The new password must be between %d and %d characters." % (MIN_LEN, MAX_LEN)
    if any(ord(c) < 0x20 or ord(c) > 0x7E for c in new):
        return False, "The new password may only contain ordinary keyboard characters."

    # PARAMETERISED, ALWAYS. This is the exact thing FluxCP got wrong: it built
    # the query by string interpolation. pymysql escapes through the driver, and
    # the account name never touches the SQL text.
    conn = pymysql.connect(**DB)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT account_id, user_pass FROM login WHERE userid = %s", (account,))
            row = cur.fetchone()
            if not row:
                return False, WRONG
            account_id, stored = row

            # REQUIRES use_MD5_passwords: yes on the login server. rAthena ships
            # it OFF, storing passwords as plain text; this refuses to work against
            # such a server rather than quietly accepting both forms, because
            # "it works" would then hide the fact that every password is readable
            # to anyone who reaches the database.
            if stored.lower() != hashlib.md5(old.encode()).hexdigest():
                return False, WRONG

            cur.execute("UPDATE login SET user_pass = %s WHERE account_id = %s",
                        (hashlib.md5(new.encode()).hexdigest(), account_id))
        conn.commit()
    finally:
        conn.close()
    return True, "Done. Use the new password the next time you log in."


class Handler(BaseHTTPRequestHandler):
    server_version = "rathena-webpw"
    sys_version = ""

    def _client_ip(self):
        # cloudflared forwards the real address here; falling back to the socket
        # would rate-limit the tunnel itself as one visitor.
        return self.headers.get("CF-Connecting-IP") or self.client_address[0]

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
        self.end_headers()
        self.wfile.write(raw)

    # RULES BEFORE THE FIELD, NOT AFTER IT. Under the button they are read only
    # by someone already looking for why something failed. And the fields carried
    # maxlength, so a longer password was SILENTLY CUT and accepted — someone
    # typing thirty characters got twenty-three, with nothing said. A form that
    # quietly edits what you typed is worse than one that refuses it, so the
    # limit is stated up front and enforced by the server alone.
    def _page(self, code=200, msg=""):
        foot = ('<footer><a href="%s">%s</a></footer>' % (SITE, SITE)) if SITE else ""
        self._send(code, PAGE % (SHARD, CSS, SHARD, msg, MIN_LEN, MAX_LEN, foot))

    def do_GET(self):
        if self.path.rstrip("/") in ("", "/health"):
            if self.path.rstrip("/") == "/health":
                return self._send(200, json.dumps({"ok": True}), "application/json")
            return self._page()
        self._send(404, "not found", "text/plain; charset=utf-8")

    def do_HEAD(self):
        # Without this BaseHTTPRequestHandler answers 501, and HEAD is what
        # uptime checks and Cloudflare reach for first — a page that works
        # perfectly in a browser can look dead to everything that watches it.
        if self.path.rstrip("/") in ("", "/health"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        ip = self._client_ip()
        if not rate_ok(ip):
            print("rate limited: %s" % ip, flush=True)
            return self._page(429, "<p class='msg err'>Too many attempts. Wait %d minutes and try again.</p>"
                              % (RATE_WINDOW // 60))
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 4096:
                return self._page(413, "<p class='msg err'>%s</p>" % WRONG)
            form = parse_qs(self.rfile.read(n).decode("utf-8", "replace"))
        except Exception:
            return self._page(400, "<p class='msg err'>%s</p>" % WRONG)

        acct = (form.get("account") or [""])[0].strip()
        old = (form.get("old") or [""])[0]
        new = (form.get("new") or [""])[0]
        new2 = (form.get("new2") or [""])[0]

        if new != new2:
            return self._page(400, "<p class='msg err'>The two new passwords do not match.</p>")
        try:
            ok, msg = change(acct, old, new)
        except Exception as e:
            print("error: %s" % e, flush=True)
            return self._page(500, "<p class='msg err'>Something went wrong on our side. Try again later.</p>")

        # LOG THE OUTCOME, NOT THE SECRET. The account name and the result are
        # what makes gamealert able to see a guessing run; the passwords are not
        # written anywhere, which is the mistake ModernUO's own flow makes when
        # it drops a desired password into a support ticket.
        print("%s %s from %s" % ("changed" if ok else "refused", acct or "-", ip), flush=True)
        self._page(200 if ok else 400,
                   "<p class='msg %s'>%s</p>" % ("ok" if ok else "err", html.escape(msg)))

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    bind = os.environ.get("BIND_ADDRESS", "0.0.0.0")
    print("rathena-webpw listening on %s:8090" % bind, flush=True)
    ThreadingHTTPServer((bind, 8090), Handler).serve_forever()
