#!/usr/bin/env python3
"""Diagnose Ghost's Admin API staff lookup — the path gated sign-in uses.

Answers, against a real Ghost:
  1. can this Admin API key list staff at all (`/users/`)?
  2. does an NQL `email:` filter on `/users/` actually match anybody?

Bonfire resolves a staff sign-in by asking Ghost for the staff user with that
email. If the filter silently matches nothing, a real contributor is told to buy
a subscription instead of being signed in.

Usage:
    GHOST_URL=https://beta.jacobin.de \\
    GHOST_ADMIN_API_KEY=<id:secret> \\
    python3 ghost_staff_lookup_check.py [email-to-look-up]

Nothing is written; the key is never printed.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.parse
import urllib.request

GHOST_URL = os.environ.get("GHOST_URL", "").rstrip("/")
ADMIN_KEY = os.environ.get("GHOST_ADMIN_API_KEY", "")
WANTED = sys.argv[1] if len(sys.argv) > 1 else None

if not GHOST_URL or not ADMIN_KEY or ":" not in ADMIN_KEY:
    sys.exit("Set GHOST_URL and GHOST_ADMIN_API_KEY (format id:secret)")


def b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def token() -> str:
    key_id, secret_hex = ADMIN_KEY.split(":", 1)
    now = int(time.time())
    header = {"alg": "HS256", "typ": "JWT", "kid": key_id}
    payload = {"iat": now, "exp": now + 300, "aud": "/admin/"}
    signing_input = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(payload).encode())}"
    sig = hmac.new(bytes.fromhex(secret_hex), signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{b64(sig)}"


def get(path: str, params: dict):
    url = f"{GHOST_URL}/ghost/api/admin{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Ghost {token()}", "Accept-Version": "v5.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:400]
    except Exception as e:  # noqa: BLE001
        return None, repr(e)


print(f"Ghost: {GHOST_URL}\n")

# 1. can we list staff at all?
status, body = get("/users/", {"limit": "5"})
print(f"[1] GET /users/            -> HTTP {status}")
if status != 200:
    print(f"    {body}")
    print("\n    The key cannot list staff. Gated sign-in CANNOT resolve any staffer.")
    sys.exit(1)

users = body.get("users", [])
total = body.get("meta", {}).get("pagination", {}).get("total", "?")
print(f"    OK — {total} staff total, first {len(users)}:")
for u in users:
    print(f"      {u.get('email')!r:45} status={u.get('status')!r} slug={u.get('slug')!r}")

probe = WANTED or (users[0].get("email") if users else None)
if not probe:
    sys.exit("\nNo staff to probe with.")

# 2. does the email filter match that same person?
nql = probe.replace("\\", "\\\\").replace("'", "\\'")
status, body = get("/users/", {"limit": "1", "filter": f"email:'{nql}'"})
matched = body.get("users", []) if isinstance(body, dict) else []
print(f"\n[2] GET /users/?filter=email:'{probe}' -> HTTP {status}, {len(matched)} match(es)")
if status != 200:
    print(f"    {body}")

print("\nVERDICT")
if status == 200 and matched:
    print("  The email filter WORKS. A failing sign-in has another cause —")
    print("  check whether the address is really on a staff record.")
else:
    print("  The email filter does NOT match a staff user that /users/ clearly lists.")
    print("  This is the sign-in bug: Bonfire must match locally instead of filtering.")
