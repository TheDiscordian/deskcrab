#!/usr/bin/env python3
"""Web Push for the phone client — RFC 8291 (message encryption), RFC 8292
(VAPID), key persistence, the subscription store, and the sender.

This is how the assistant reaches the phone when the page is CLOSED: the
browser's push service (FCM for Chrome, autopush for Firefox, APNs for iOS
Safari) holds a channel to the device, and we POST an encrypted payload to the
subscription's endpoint. The service worker's `push` handler shows it as a
system notification. Nothing here is a message relay — the payload is encrypted
to the subscription's own keys, so the push service never sees the text.

Dependency note: serve.py is stdlib-only on purpose, and this is the one thing
stdlib cannot do (ECDH + AES-GCM). `cryptography` is a system package here, so
serve.py imports this module OPTIONALLY, exactly like `markdown`: if the import
fails, the push endpoints answer 501 and the rest of the server is unaffected.
Never make it a hard import at the top of serve.py.

State lives under ~/.local/share/deskcrab/webpush/ (DESKCRAB_PUSH_DIR to
override — tests use a scratch dir):
  vapid.json          one keypair, generated on first use and kept forever;
                      changing it invalidates every existing subscription
  subscriptions.json  {endpoint: subscription}, idempotent by endpoint

The crypto core is verified byte-for-byte against the RFC 8291 section 5 test
vector: `python3 webpush.py selftest`.
"""
import base64
import fcntl
import hashlib
import hmac
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PUSH_DIR = Path(os.environ.get("DESKCRAB_PUSH_DIR")
                or os.path.join(os.environ.get("XDG_DATA_HOME")
                                or os.path.expanduser("~/.local/share"),
                                "deskcrab", "webpush"))
VAPID_FILE = PUSH_DIR / "vapid.json"
SUBS_FILE = PUSH_DIR / "subscriptions.json"
LOCK_FILE = PUSH_DIR / "lock"

# Who is sending, for the push service's abuse desk (RFC 8292 `sub` claim).
# A URL identifying the project is valid and needs no email address.
SUBJECT = (os.environ.get("DESKCRAB_PUSH_SUBJECT", "").strip()
           or "https://github.com/TheDiscordian/deskcrab")
TTL = int(os.environ.get("DESKCRAB_PUSH_TTL", "86400"))


def b64d(s):
    if isinstance(s, str):
        s = s.encode()
    return base64.urlsafe_b64decode(s + b"=" * (-len(s) % 4))


def b64e(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _hkdf(salt, ikm, info, length):
    """HKDF-SHA256 with a single output block — all Web Push needs."""
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:length]


def _raw_public(priv):
    return priv.public_key().public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint,
    )


# --- RFC 8291: encrypting the payload ---------------------------------------


def encrypt(plaintext, ua_public, auth_secret, as_private=None, salt=None, rs=4096):
    """Build an `aes128gcm` body (RFC 8188) keyed per RFC 8291.

    ua_public / auth_secret come from the browser's PushSubscription
    (`keys.p256dh` and `keys.auth`, both base64url). as_private and salt are
    parameters only so the RFC test vector can be reproduced — in real use they
    are freshly generated per message, and must be.
    """
    if as_private is None:
        as_private = ec.generate_private_key(ec.SECP256R1())
    if salt is None:
        salt = os.urandom(16)

    as_public = _raw_public(as_private)
    ua_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_public)
    ecdh = as_private.exchange(ec.ECDH(), ua_key)

    # RFC 8291 §3.4 — the subscription's auth secret salts the raw ECDH output
    # into the IKM, so knowing the ECDH shared secret alone is not enough.
    key_info = b"WebPush: info\x00" + ua_public + as_public
    ikm = _hkdf(auth_secret, ecdh, key_info, 32)

    cek = _hkdf(salt, ikm, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = _hkdf(salt, ikm, b"Content-Encoding: nonce\x00", 12)

    # One record only. 0x02 is the last-record delimiter (RFC 8188 §2); using
    # 0x01 here is the classic bug that makes a push silently fail to decrypt.
    body = AESGCM(cek).encrypt(nonce, plaintext + b"\x02", None)
    header = salt + struct.pack("!L", rs) + bytes([len(as_public)]) + as_public
    return header + body


# --- RFC 8292: proving who is sending ---------------------------------------


def vapid_header(endpoint, private_b64, subject, ttl=12 * 3600):
    """Return the Authorization header value for a push request.

    `aud` is the ORIGIN of the endpoint, not the whole URL — getting that wrong
    is the usual cause of a 401 from the push service.
    """
    from urllib.parse import urlparse

    u = urlparse(endpoint)
    claims = {
        "aud": f"{u.scheme}://{u.netloc}",
        "exp": int(time.time()) + ttl,
        "sub": subject,
    }
    header = b64e(json.dumps({"typ": "JWT", "alg": "ES256"}, separators=(",", ":")).encode())
    payload = b64e(json.dumps(claims, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()

    priv = ec.derive_private_key(int.from_bytes(b64d(private_b64), "big"), ec.SECP256R1())
    der = priv.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    # JWS wants raw r||s, not the DER sequence `cryptography` hands back.
    r, s = utils.decode_dss_signature(der)
    sig = b64e(r.to_bytes(32, "big") + s.to_bytes(32, "big"))

    return f"vapid t={header}.{payload}.{sig}, k={b64e(_raw_public(priv))}"


# --- persistence -------------------------------------------------------------


@contextmanager
def _locked():
    """One writer at a time across serve.py threads AND crab notify processes."""
    PUSH_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(PUSH_DIR, 0o700)
    with open(LOCK_FILE, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        yield


def _write_json(path, doc):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, indent=1))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def vapid_keys():
    """The one VAPID keypair, generated on first use. Returns (private, public)
    as base64url. The public key goes to the browser at subscribe time;
    regenerating would orphan every subscription, so it never happens twice."""
    with _locked():
        try:
            doc = json.loads(VAPID_FILE.read_text())
            return doc["private"], doc["public"]
        except (OSError, ValueError, KeyError):
            pass
        priv = ec.generate_private_key(ec.SECP256R1())
        raw = priv.private_numbers().private_value.to_bytes(32, "big")
        doc = {"private": b64e(raw), "public": b64e(_raw_public(priv))}
        _write_json(VAPID_FILE, doc)
        return doc["private"], doc["public"]


def _load_subs():
    try:
        doc = json.loads(SUBS_FILE.read_text())
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def valid_subscription(sub):
    """Shape-check a PushSubscription before it is stored: a malformed one
    would otherwise fail cryptically at send time, long after the phone that
    produced it is gone."""
    try:
        if not sub["endpoint"].startswith(("https://", "http://")):
            return False
        p256dh = b64d(sub["keys"]["p256dh"])
        auth = b64d(sub["keys"]["auth"])
        return len(p256dh) == 65 and p256dh[0] == 4 and len(auth) == 16
    except (KeyError, TypeError, ValueError):
        return False


def add_subscription(sub):
    """Store one subscription, idempotent by endpoint. Returns the store size."""
    keep = {"endpoint": sub["endpoint"],
            "keys": {"p256dh": sub["keys"]["p256dh"],
                     "auth": sub["keys"]["auth"]}}
    with _locked():
        subs = _load_subs()
        subs[keep["endpoint"]] = keep
        _write_json(SUBS_FILE, subs)
        return len(subs)


def remove_subscription(endpoint):
    with _locked():
        subs = _load_subs()
        removed = subs.pop(endpoint, None) is not None
        _write_json(SUBS_FILE, subs)
        return removed, len(subs)


def list_subscriptions():
    with _locked():
        return list(_load_subs().values())


# --- sending -----------------------------------------------------------------


def _short(endpoint):
    """The endpoint is a capability URL — the full token in a log would let
    anyone who reads the log push to the phone."""
    from urllib.parse import urlparse
    u = urlparse(endpoint)
    return f"{u.netloc}…{endpoint[-8:]}"


def send_one(sub, payload, private_b64, subject=SUBJECT, ttl=TTL):
    """POST one encrypted push. Returns (status, detail); status is the HTTP
    code, or 0 for a transport error described by detail."""
    body = encrypt(payload, b64d(sub["keys"]["p256dh"]), b64d(sub["keys"]["auth"]))
    req = urllib.request.Request(sub["endpoint"], data=body, method="POST", headers={
        "TTL": str(ttl),
        "Urgency": "high",
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        "Authorization": vapid_header(sub["endpoint"], private_b64, subject),
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, ""
    except urllib.error.HTTPError as e:
        return e.code, (e.read(300).decode("utf-8", "replace") or e.reason)
    except (urllib.error.URLError, OSError) as e:
        return 0, str(e)[:200]


def send_all(payload_doc):
    """Send to every stored subscription; report each; prune the dead.

    A 404/410 is the push service saying the subscription no longer exists
    (app uninstalled, permission revoked, endpoint rotated) — keeping it would
    fail identically forever, so it is removed on the spot.
    Exit meaning for the CLI: 0 = at least one delivery accepted, 1 = nothing
    to send or nothing accepted.
    """
    subs = list_subscriptions()
    if not subs:
        print("No push subscriptions — nothing to send.")
        print("Subscribe from the phone page first (the bell button).")
        return 1
    private_b64, _ = vapid_keys()
    payload = json.dumps(payload_doc, separators=(",", ":")).encode()
    ok = 0
    for sub in subs:
        status, detail = send_one(sub, payload, private_b64)
        where = _short(sub["endpoint"])
        if status in (200, 201):
            ok += 1
            print(f"  ok    {status}  {where}")
        elif status in (404, 410):
            remove_subscription(sub["endpoint"])
            print(f"  gone  {status}  {where}  (pruned)")
        else:
            print(f"  FAIL  {status or 'net'}  {where}  {detail}")
    print(f"{ok}/{len(subs)} accepted by the push service.")
    return 0 if ok else 1


# --- self-test ----------------------------------------------------------------

def selftest():
    # RFC 8291 section 5, byte for byte.
    expected = (
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
        "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT"
        "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
    )
    body = encrypt(
        b"When I grow up, I want to be a watermelon",
        b64d("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"),
        b64d("BTBZMqHH6r4Tts7J_aSIgg"),
        as_private=ec.derive_private_key(
            int.from_bytes(b64d("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"), "big"),
            ec.SECP256R1(),
        ),
        salt=b64d(expected)[:16],
    )
    assert b64e(body) == expected, "RFC 8291 vector MISMATCH"
    print("RFC 8291 §5 vector: MATCH")

    # VAPID: sign, then verify the signature with the advertised public key.
    priv = ec.generate_private_key(ec.SECP256R1())
    priv_b64 = b64e(priv.private_numbers().private_value.to_bytes(32, "big"))
    hdr = vapid_header("https://fcm.googleapis.com/fcm/send/abc123", priv_b64, SUBJECT)
    tok = hdr.split("t=")[1].split(",")[0]
    k = b64d(hdr.split("k=")[1])
    h, p, s = tok.split(".")
    sig = b64d(s)
    ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), k).verify(
        utils.encode_dss_signature(
            int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")
        ),
        f"{h}.{p}".encode(),
        ec.ECDSA(hashes.SHA256()),
    )
    claims = json.loads(b64d(p))
    assert claims["aud"] == "https://fcm.googleapis.com", claims["aud"]
    print("VAPID JWT: signature verifies, aud =", claims["aud"])


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "vapid-public":
        print(vapid_keys()[1])
        return 0
    if cmd == "subscribe":
        sub = json.load(sys.stdin)
        if not valid_subscription(sub):
            print("not a valid PushSubscription", file=sys.stderr)
            return 1
        print(add_subscription(sub))
        return 0
    if cmd == "unsubscribe" and len(argv) > 2:
        removed, left = remove_subscription(argv[2])
        print(f"{'removed' if removed else 'not found'}; {left} left")
        return 0
    if cmd == "list":
        for sub in list_subscriptions():
            print(_short(sub["endpoint"]))
        return 0
    if cmd == "send" and len(argv) > 3:
        return send_all({"title": argv[2], "body": " ".join(argv[3:]), "url": "/"})
    if cmd == "selftest":
        selftest()
        return 0
    print("Usage: webpush.py vapid-public | subscribe (JSON on stdin) | "
          "unsubscribe <endpoint> | list | send <title> <body…> | selftest",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
