#!/usr/bin/env python3
"""novnc-auth: token-based access control for noVNC.

All endpoints bind to 127.0.0.1 only. Nginx is the sole public entry point.

Endpoints:
  GET  /access?token=<tok>
       Validates the signed token, sets an HttpOnly access cookie, and
       redirects the browser to /vnc.html?autoconnect=1&resize=remote.
       Called once per session when the user opens the desktop-url link.

  GET  /verify
       Reads the access cookie and returns 200 (allow) or 401 (deny).
       When 200, includes X-VNC-Backend: 127.0.0.1:<port> so nginx can
       route the request to the correct per-user websockify process.
       Called on every request by nginx via auth_request.

  POST /generate?user=<name>
       Mints a new user-scoped signed token and returns JSON containing
       the full access URL. Only reachable from localhost; nginx blocks
       external access. Returns 404 if the user is not registered.

  POST /register
       Body: {"user": "<name>", "display": N, "ws_port": M}
       Adds or updates the user in the registry. Localhost only.

  GET  /user-status?user=<name>
       Returns the user's registry entry or 404 if not registered.
       Localhost only.
"""

import hashlib
import hmac
import http.server
import json
import os
import secrets
import sys
import tempfile
import time
import urllib.parse
from base64 import urlsafe_b64decode, urlsafe_b64encode

SECRET_FILE = "/etc/novnc-auth/secret"
CONFIG_FILE = "/etc/novnc-auth/config.json"
USERS_FILE = "/etc/novnc-auth/users.json"
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8898
COOKIE_NAME = "novnc_access"

DEFAULT_REDIRECT = "/vnc.html?autoconnect=1&resize=remote"


def _load_secret() -> bytes:
    with open(SECRET_FILE) as fh:
        return fh.read().strip().encode()


def _load_config() -> dict:
    cfg = {"ttl_seconds": 28800, "base_url": "https://localhost"}
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as fh:
            cfg.update(json.load(fh))
    return cfg


def _load_users() -> dict:
    if not os.path.exists(USERS_FILE):
        return {}
    with open(USERS_FILE) as fh:
        try:
            return json.load(fh)
        except json.JSONDecodeError:
            return {}


def _save_users(users: dict) -> None:
    """Write users atomically so a partial write never corrupts the registry."""
    dir_path = os.path.dirname(USERS_FILE)
    fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".users.json.")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(users, fh, indent=2)
        os.rename(tmp_path, USERS_FILE)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _b64url_encode(data: bytes) -> str:
    return urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64url_decode(s: str) -> bytes:
    pad = 4 - len(s) % 4
    if pad != 4:
        s += "=" * pad
    return urlsafe_b64decode(s)


def _sign(secret: bytes, payload: str) -> str:
    return _b64url_encode(
        hmac.new(secret, payload.encode(), hashlib.sha256).digest()
    )


def make_token(
    secret: bytes, ttl_seconds: int, username: str, ws_port: int
) -> tuple[str, int]:
    """Return (token, expiry_ms). Token payload includes username and ws_port."""
    expiry_ms = int((time.time() + ttl_seconds) * 1000)
    payload = _b64url_encode(
        json.dumps({"u": username, "e": expiry_ms, "p": ws_port}).encode()
    )
    sig = _sign(secret, payload)
    return f"{payload}.{sig}", expiry_ms


def verify_token(
    secret: bytes, token: str
) -> tuple[bool, str | None, int | None]:
    """Validate signature and expiry. Returns (valid, username, ws_port)."""
    try:
        payload, sig = token.rsplit(".", 1)
        expected = _sign(secret, payload)
        if not hmac.compare_digest(sig, expected):
            return False, None, None
        data = json.loads(_b64url_decode(payload))
        if int(time.time() * 1000) >= int(data["e"]):
            return False, None, None
        return True, str(data["u"]), int(data["p"])
    except Exception:
        return False, None, None


def _cookie_value(header: str, name: str) -> str:
    for part in header.split(";"):
        k, _, v = part.strip().partition("=")
        if k.strip() == name:
            return v.strip()
    return ""


def _is_localhost(handler: "http.server.BaseHTTPRequestHandler") -> bool:
    return handler.client_address[0] == "127.0.0.1"


class _AuthHandler(http.server.BaseHTTPRequestHandler):
    # Cached at class level; reloaded only on restart.
    _secret: bytes | None = None
    _config: dict | None = None

    @property
    def secret(self) -> bytes:
        if _AuthHandler._secret is None:
            _AuthHandler._secret = _load_secret()
        return _AuthHandler._secret

    @property
    def config(self) -> dict:
        if _AuthHandler._config is None:
            _AuthHandler._config = _load_config()
        return _AuthHandler._config

    def log_message(self, *args, **kwargs):  # noqa: D102
        pass

    def _send_json(self, code: int, data: dict) -> None:
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b""

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/access":
            self._handle_access(parsed)
        elif parsed.path == "/verify":
            self._handle_verify()
        elif parsed.path == "/user-status":
            self._handle_user_status(parsed)
        else:
            self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/generate":
            self._handle_generate(parsed)
        elif parsed.path == "/register":
            self._handle_register()
        else:
            self.send_error(404)

    # ------------------------------------------------------------------
    # Handlers
    # ------------------------------------------------------------------

    def _handle_access(self, parsed: urllib.parse.ParseResult) -> None:
        """Exchange a signed token for an HttpOnly cookie and redirect."""
        qs = urllib.parse.parse_qs(parsed.query)
        token = qs.get("token", [""])[0]
        redirect = qs.get("redirect", [DEFAULT_REDIRECT])[0]

        if not redirect.startswith("/") or redirect.startswith("//"):
            redirect = DEFAULT_REDIRECT

        valid, _, _ = verify_token(self.secret, token)
        if not valid:
            body = (
                b"<!DOCTYPE html><html><head><title>Link Expired</title>"
                b"<style>body{font-family:sans-serif;max-width:480px;margin:4rem auto;padding:0 1rem}"
                b"h1{color:#c0392b}p{color:#555}</style></head><body>"
                b"<h1>Link Expired</h1>"
                b"<p>This desktop link has expired or is invalid.</p>"
                b"<p>Connect via SSH and run <code>novnc-desktop-url</code> to generate a new link.</p>"
                b"</body></html>"
            )
            self.send_response(401)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        proto = self.headers.get("X-Forwarded-Proto", "https")
        secure = "; Secure" if proto == "https" else ""
        cookie = (
            f"{COOKIE_NAME}={token}; HttpOnly; SameSite=Lax; Path=/{secure}; "
            f"Max-Age={self.config['ttl_seconds']}"
        )
        self.send_response(302)
        self.send_header("Set-Cookie", cookie)
        self.send_header("Location", redirect)
        self.end_headers()

    def _handle_verify(self) -> None:
        """Check the access cookie. Returns 200 + X-VNC-Backend or 401."""
        cookie_header = self.headers.get("Cookie", "")
        token = _cookie_value(cookie_header, COOKIE_NAME)
        valid, _, ws_port = verify_token(self.secret, token)
        if valid and ws_port is not None:
            self.send_response(200)
            self.send_header("X-VNC-Backend", f"127.0.0.1:{ws_port}")
            self.end_headers()
        else:
            self.send_response(401)
            self.end_headers()

    def _handle_generate(self, parsed: urllib.parse.ParseResult) -> None:
        """Mint a user-scoped token. Localhost only."""
        if not _is_localhost(self):
            self.send_error(403)
            return

        qs = urllib.parse.parse_qs(parsed.query)
        username = qs.get("user", [""])[0].strip()
        if not username:
            self._send_json(400, {"error": "Missing required query parameter: user"})
            return

        users = _load_users()
        entry = users.get(username)
        if entry is None:
            self._send_json(
                404,
                {
                    "error": (
                        f"User '{username}' is not registered. "
                        "Run 'novnc-desktop-url' after the desktop is set up, "
                        "or call POST /register to register the user manually."
                    )
                },
            )
            return

        # Verify the caller-supplied key matches the per-user gen_key stored in
        # the registry. This prevents a local user from minting tokens for
        # another user's session. Only the user who ran novnc-user-setup can
        # read their own key from ~/.novnc-gen-key.
        stored_key = entry.get("gen_key", "")
        if stored_key:
            provided_key = qs.get("key", [""])[0]
            if not hmac.compare_digest(provided_key, stored_key):
                self._send_json(403, {"error": "Invalid or missing gen_key"})
                return

        ws_port = int(entry["ws_port"])
        token, expiry_ms = make_token(
            self.secret, self.config["ttl_seconds"], username, ws_port
        )
        base_url = self.config["base_url"].rstrip("/")
        url = f"{base_url}/access?token={urllib.parse.quote(token, safe='')}"
        expiry_iso = time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime(expiry_ms / 1000)
        )
        self._send_json(
            200,
            {"url": url, "token": token, "expires_at": expiry_iso},
        )

    def _handle_register(self) -> None:
        """Register or update a user in the registry. Localhost only."""
        if not _is_localhost(self):
            self.send_error(403)
            return

        try:
            body = json.loads(self._read_body())
        except (json.JSONDecodeError, ValueError):
            self._send_json(400, {"error": "Invalid JSON body"})
            return

        username = str(body.get("user", "")).strip()
        display = body.get("display")
        ws_port = body.get("ws_port")

        if not username or display is None or ws_port is None:
            self._send_json(
                400,
                {"error": "Body must include: user (string), display (int), ws_port (int)"},
            )
            return

        try:
            display_int = int(display)
            ws_port_int = int(ws_port)
        except (ValueError, TypeError):
            self._send_json(400, {"error": "display and ws_port must be integers"})
            return

        if not (1 <= display_int <= 9999):
            self._send_json(400, {"error": "display must be between 1 and 9999"})
            return

        # Restrict ws_port to the websockify range to prevent SSRF to other
        # local services. nginx proxies to ws_port from the signed token.
        if not (6001 <= ws_port_int <= 9999):
            self._send_json(400, {"error": "ws_port must be between 6001 and 9999"})
            return

        gen_key = secrets.token_hex(16)
        entry = {"display": display_int, "ws_port": ws_port_int, "gen_key": gen_key}
        users = _load_users()
        users[username] = entry
        _save_users(users)
        self._send_json(200, {"user": username, "display": display_int, "ws_port": ws_port_int, "gen_key": gen_key})

    def _handle_user_status(self, parsed: urllib.parse.ParseResult) -> None:
        """Return user registry entry. Localhost only."""
        if not _is_localhost(self):
            self.send_error(403)
            return

        qs = urllib.parse.parse_qs(parsed.query)
        username = qs.get("user", [""])[0].strip()
        if not username:
            self._send_json(400, {"error": "Missing required query parameter: user"})
            return

        users = _load_users()
        entry = users.get(username)
        if entry is None:
            self._send_json(404, {"error": f"User '{username}' is not registered"})
            return

        self._send_json(200, {"user": username, **entry})


if __name__ == "__main__":
    server = http.server.HTTPServer((LISTEN_HOST, LISTEN_PORT), _AuthHandler)
    print(f"novnc-auth listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
