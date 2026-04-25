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
       Called on every request by nginx via auth_request.

  POST /generate
       Mints a new signed token and returns JSON containing the full access
       URL. Only reachable from localhost; nginx blocks external access.
"""

import hashlib
import hmac
import http.server
import json
import os
import sys
import time
import urllib.parse
from base64 import urlsafe_b64decode, urlsafe_b64encode

SECRET_FILE = "/etc/novnc-auth/secret"
CONFIG_FILE = "/etc/novnc-auth/config.json"
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8898
COOKIE_NAME = "novnc_access"

# Default redirect after a successful token exchange.
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


def make_token(secret: bytes, ttl_seconds: int) -> tuple[str, int]:
    """Return (token, expiry_ms)."""
    expiry_ms = int((time.time() + ttl_seconds) * 1000)
    payload = _b64url_encode(json.dumps({"e": expiry_ms}).encode())
    sig = _sign(secret, payload)
    return f"{payload}.{sig}", expiry_ms


def verify_token(secret: bytes, token: str) -> bool:
    """Return True iff the token has a valid signature and has not expired."""
    try:
        payload, sig = token.rsplit(".", 1)
        expected = _sign(secret, payload)
        if not hmac.compare_digest(sig, expected):
            return False
        data = json.loads(_b64url_decode(payload))
        return int(time.time() * 1000) < int(data["e"])
    except Exception:
        return False


def _cookie_value(header: str, name: str) -> str:
    for part in header.split(";"):
        k, _, v = part.strip().partition("=")
        if k.strip() == name:
            return v.strip()
    return ""


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

    # Suppress the default per-request log line; errors still go to stderr.
    def log_message(self, format, *args):  # noqa: D102 A002
        pass

    def _send_json(self, code: int, data: dict) -> None:
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/access":
            self._handle_access(parsed)
        elif parsed.path == "/verify":
            self._handle_verify()
        else:
            self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/generate":
            self._handle_generate()
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

        # Sanitise redirect to relative paths only to prevent open redirects.
        if not redirect.startswith("/") or redirect.startswith("//"):
            redirect = DEFAULT_REDIRECT

        if not verify_token(self.secret, token):
            # Bad or expired token — redirect to noVNC root (will hit auth again).
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
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
        """Check the access cookie. Called internally by nginx auth_request."""
        cookie_header = self.headers.get("Cookie", "")
        token = _cookie_value(cookie_header, COOKIE_NAME)
        if token and verify_token(self.secret, token):
            self.send_response(200)
            self.end_headers()
        else:
            self.send_response(401)
            self.end_headers()

    def _handle_generate(self) -> None:
        """Mint a new token and return the full access URL as JSON."""
        token, expiry_ms = make_token(self.secret, self.config["ttl_seconds"])
        base_url = self.config["base_url"].rstrip("/")
        url = f"{base_url}/access?token={urllib.parse.quote(token, safe='')}"
        expiry_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(expiry_ms / 1000))
        self._send_json(200, {
            "url": url,
            "token": token,
            "expires_at": expiry_iso,
        })


if __name__ == "__main__":
    server = http.server.HTTPServer((LISTEN_HOST, LISTEN_PORT), _AuthHandler)
    print(f"novnc-auth listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
