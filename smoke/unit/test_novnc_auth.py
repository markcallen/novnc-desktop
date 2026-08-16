#!/usr/bin/env python3
"""Unit tests for novnc-auth.py token functions.

Tests make_token(), verify_token(), and the underlying crypto helpers
without starting the HTTP server. These tests are self-contained and
require only the Python standard library.

Run:
    python3 -m unittest smoke/unit/test_novnc_auth.py -v
    # or via pnpm:
    pnpm test:unit:auth
"""

import importlib.util
import json
import os
import time
import unittest

# ---------------------------------------------------------------------------
# Load novnc-auth.py via importlib (filename contains a hyphen).
# ---------------------------------------------------------------------------
_AUTH_PATH = os.path.join(
    os.path.dirname(__file__),
    "../../roles/auth/files/novnc-auth.py",
)
_spec = importlib.util.spec_from_file_location("novnc_auth", _AUTH_PATH)
assert _spec is not None and _spec.loader is not None, f"Could not load {_AUTH_PATH}"
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)  # type: ignore[union-attr]

make_token = _mod.make_token
verify_token = _mod.verify_token
_b64url_encode = _mod._b64url_encode
_b64url_decode = _mod._b64url_decode
_sign = _mod._sign

# ---------------------------------------------------------------------------
# Shared test fixtures
# ---------------------------------------------------------------------------
_SECRET = b"unit-test-secret-value-xyz"
_TTL = 28800
_USER = "alice"
_PORT = 6081


class TestMakeVerifyRoundtrip(unittest.TestCase):
    """make_token() / verify_token() basic roundtrip (FR-9.2)."""

    def test_valid_token_accepted(self):
        token, _ = make_token(_SECRET, _TTL, _USER, _PORT)
        valid, username, ws_port = verify_token(_SECRET, token)
        self.assertTrue(valid)
        self.assertEqual(username, _USER)
        self.assertEqual(ws_port, _PORT)

    def test_expiry_is_in_future(self):
        _, expiry_ms = make_token(_SECRET, _TTL, _USER, _PORT)
        self.assertGreater(expiry_ms, int(time.time() * 1000))

    def test_expiry_is_approximately_ttl_seconds_ahead(self):
        before_ms = int(time.time() * 1000)
        _, expiry_ms = make_token(_SECRET, _TTL, _USER, _PORT)
        after_ms = int(time.time() * 1000)
        self.assertGreaterEqual(expiry_ms, before_ms + _TTL * 1000)
        self.assertLessEqual(expiry_ms, after_ms + _TTL * 1000)

    def test_expired_token_rejected(self):
        """TTL of -1 produces a token that is already expired."""
        token, _ = make_token(_SECRET, -1, _USER, _PORT)
        valid, _, _ = verify_token(_SECRET, token)
        self.assertFalse(valid)

    def test_wrong_secret_rejected(self):
        token, _ = make_token(_SECRET, _TTL, _USER, _PORT)
        valid, _, _ = verify_token(b"wrong-secret", token)
        self.assertFalse(valid)

    def test_verify_returns_none_fields_on_failure(self):
        valid, username, ws_port = verify_token(_SECRET, "bad.token.here")
        self.assertFalse(valid)
        self.assertIsNone(username)
        self.assertIsNone(ws_port)


class TestTokenTampering(unittest.TestCase):
    """Tampered tokens must always be rejected (FR-9.2)."""

    def _parts(self, token: str) -> tuple[str, dict, str]:
        payload_b64, sig = token.rsplit(".", 1)
        data = json.loads(_b64url_decode(payload_b64))
        return payload_b64, data, sig

    def _forge(self, data: dict, sig: str) -> str:
        """Re-encode a (possibly modified) payload with the original signature."""
        tampered_b64 = _b64url_encode(json.dumps(data).encode())
        return f"{tampered_b64}.{sig}"

    def test_tampered_signature_rejected(self):
        token, _ = make_token(_SECRET, _TTL, _USER, _PORT)
        payload, sig = token.rsplit(".", 1)
        bad_sig = sig[:-1] + ("A" if sig[-1] != "A" else "B")
        valid, _, _ = verify_token(_SECRET, f"{payload}.{bad_sig}")
        self.assertFalse(valid)

    def test_tampered_username_rejected(self):
        token, _ = make_token(_SECRET, _TTL, _USER, _PORT)
        _, data, sig = self._parts(token)
        data["u"] = "evil_attacker"
        valid, _, _ = verify_token(_SECRET, self._forge(data, sig))
        self.assertFalse(valid)

    def test_tampered_ws_port_rejected(self):
        """An attacker changing the ws_port in the payload must be caught."""
        token, _ = make_token(_SECRET, _TTL, _USER, _PORT)
        _, data, sig = self._parts(token)
        data["p"] = 9999
        valid, _, _ = verify_token(_SECRET, self._forge(data, sig))
        self.assertFalse(valid)

    def test_tampered_expiry_extension_rejected(self):
        """Extending the expiry timestamp without a valid signature is rejected."""
        token, _ = make_token(_SECRET, _TTL, _USER, _PORT)
        _, data, sig = self._parts(token)
        data["e"] = data["e"] + 999_999_999
        valid, _, _ = verify_token(_SECRET, self._forge(data, sig))
        self.assertFalse(valid)

    def test_expired_then_expiry_extended_rejected(self):
        """Expired token with tampered expiry to extend validity is still rejected."""
        token, _ = make_token(_SECRET, -1, _USER, _PORT)
        _, data, sig = self._parts(token)
        # Push expiry far into the future
        data["e"] = int((time.time() + 99999) * 1000)
        valid, _, _ = verify_token(_SECRET, self._forge(data, sig))
        self.assertFalse(valid)

    def test_reordered_json_keys_rejected(self):
        """Reordering JSON keys changes the base64 encoding, invalidating the sig."""
        token, _ = make_token(_SECRET, _TTL, _USER, _PORT)
        _, data, sig = self._parts(token)
        # Reverse key order so re-serialised payload differs from original
        reversed_data = {k: data[k] for k in reversed(list(data))}
        valid, _, _ = verify_token(_SECRET, self._forge(reversed_data, sig))
        self.assertFalse(valid)


class TestMalformedTokens(unittest.TestCase):
    """Edge-case and garbage inputs must not crash verify_token."""

    CASES = [
        "",
        "notavalidtoken",
        "only.one",
        "a.b.c.d",
        ".",
        "..",
        "   ",
        "eyJhbGciOiJub25lIn0=.eyJ1IjoieCJ9.",  # None-alg JWT-like
    ]

    def test_malformed_inputs_rejected_without_exception(self):
        for bad in self.CASES:
            with self.subTest(token=repr(bad)):
                valid, u, p = verify_token(_SECRET, bad)
                self.assertFalse(valid, f"Should reject: {bad!r}")
                self.assertIsNone(u)
                self.assertIsNone(p)

    def test_truncated_token_rejected(self):
        token, _ = make_token(_SECRET, _TTL, _USER, _PORT)
        valid, _, _ = verify_token(_SECRET, token[:10])
        self.assertFalse(valid)

    def test_empty_payload_segment_rejected(self):
        _, sig = make_token(_SECRET, _TTL, _USER, _PORT)[0].rsplit(".", 1)
        valid, _, _ = verify_token(_SECRET, f".{sig}")
        self.assertFalse(valid)


class TestUsernameAndPortPreservation(unittest.TestCase):
    """Tokens must faithfully round-trip the username and ws_port (FR-9.2)."""

    USERNAMES = ["alice", "bob", "user.name", "user-123", "user_x", "ubuntu"]
    PORTS = [6001, 6081, 7000, 9999]

    def test_usernames_preserved(self):
        for user in self.USERNAMES:
            with self.subTest(user=user):
                token, _ = make_token(_SECRET, _TTL, user, _PORT)
                _, username, _ = verify_token(_SECRET, token)
                self.assertEqual(username, user)

    def test_ws_ports_preserved(self):
        for port in self.PORTS:
            with self.subTest(port=port):
                token, _ = make_token(_SECRET, _TTL, _USER, port)
                _, _, ws_port = verify_token(_SECRET, token)
                self.assertEqual(ws_port, port)

    def test_distinct_tokens_for_different_users(self):
        token_a, _ = make_token(_SECRET, _TTL, "alice", _PORT)
        token_b, _ = make_token(_SECRET, _TTL, "bob", _PORT)
        self.assertNotEqual(token_a, token_b)

    def test_distinct_tokens_for_different_ports(self):
        token_a, _ = make_token(_SECRET, _TTL, _USER, 6081)
        token_b, _ = make_token(_SECRET, _TTL, _USER, 6082)
        self.assertNotEqual(token_a, token_b)


class TestB64url(unittest.TestCase):
    """_b64url_encode / _b64url_decode roundtrip and encoding properties."""

    def test_roundtrip(self):
        for data in [b"hello", b"\x00\xff\xfe", b"a" * 100, b""]:
            with self.subTest(data=data):
                self.assertEqual(_b64url_decode(_b64url_encode(data)), data)

    def test_no_padding_characters(self):
        for data in [b"a", b"ab", b"abc", b"abcd"]:
            encoded = _b64url_encode(data)
            self.assertNotIn("=", encoded, f"Padding found for {data!r}")

    def test_url_safe_characters_only(self):
        # Every possible byte value should encode to URL-safe base64 chars
        for i in range(256):
            encoded = _b64url_encode(bytes([i]))
            self.assertRegex(
                encoded,
                r"^[A-Za-z0-9_-]+$",
                f"Non-URL-safe char for byte {i}",
            )


class TestSignConsistency(unittest.TestCase):
    """_sign must be deterministic and sensitive to both secret and payload."""

    def test_deterministic(self):
        self.assertEqual(_sign(_SECRET, "hello"), _sign(_SECRET, "hello"))

    def test_different_payload_different_sig(self):
        self.assertNotEqual(_sign(_SECRET, "payload1"), _sign(_SECRET, "payload2"))

    def test_different_secret_different_sig(self):
        self.assertNotEqual(_sign(b"secret1", "payload"), _sign(b"secret2", "payload"))

    def test_output_is_non_empty_string(self):
        sig = _sign(_SECRET, "test")
        self.assertIsInstance(sig, str)
        self.assertGreater(len(sig), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
