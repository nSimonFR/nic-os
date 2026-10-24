"""The slice of Bitwarden's client-side crypto a password change needs.

Master key from the KDF, the server-side login hash, and type-2 EncStrings
(AES-256-CBC + HMAC-SHA256) to unwrap and rewrap the user key. `cryptography`
is imported lazily so the package still imports without it.
"""

import base64
import hashlib
import hmac
import os

PBKDF2 = 0
ARGON2ID = 1


def master_key(password, email, kdf):
    """`kdf` = {"type", "iterations", "memory" (MiB), "parallelism"} from prelogin."""
    salt = email.strip().lower().encode()
    pw = password.encode()
    if kdf["type"] == PBKDF2:
        return hashlib.pbkdf2_hmac("sha256", pw, salt, kdf["iterations"], 32)
    if kdf["type"] == ARGON2ID:
        from cryptography.hazmat.primitives.kdf.argon2 import Argon2id

        return Argon2id(
            salt=hashlib.sha256(salt).digest(),
            length=32,
            iterations=kdf["iterations"],
            lanes=kdf["parallelism"],
            memory_cost=kdf["memory"] * 1024,
        ).derive(pw)
    raise ValueError(f"unsupported KDF type {kdf['type']}")


def password_hash(mkey, password):
    """What the server stores and checks: one PBKDF2 round of the master key."""
    raw = hashlib.pbkdf2_hmac("sha256", mkey, password.encode(), 1, 32)
    return base64.b64encode(raw).decode()


def _hkdf_expand(prk, info):
    # One SHA-256 block is exactly the 32 bytes asked for.
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()


def stretch(mkey):
    """(enc_key, mac_key) that wrap the user key."""
    return _hkdf_expand(mkey, b"enc"), _hkdf_expand(mkey, b"mac")


def decrypt(encstring, enc_key, mac_key):
    kind, _, rest = encstring.partition(".")
    if kind != "2":
        raise ValueError(f"unsupported EncString type {kind}")
    iv, ct, mac = (base64.b64decode(p) for p in rest.split("|"))
    want = hmac.new(mac_key, iv + ct, hashlib.sha256).digest()
    if not hmac.compare_digest(want, mac):
        raise ValueError("EncString MAC mismatch (wrong password?)")

    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    dec = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).decryptor()
    padded = dec.update(ct) + dec.finalize()
    unpad = padding.PKCS7(128).unpadder()
    return unpad.update(padded) + unpad.finalize()


def encrypt(data, enc_key, mac_key, iv=None):
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    iv = iv or os.urandom(16)
    pad = padding.PKCS7(128).padder()
    padded = pad.update(data) + pad.finalize()
    enc = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).encryptor()
    ct = enc.update(padded) + enc.finalize()
    mac = hmac.new(mac_key, iv + ct, hashlib.sha256).digest()
    b64 = lambda b: base64.b64encode(b).decode()  # noqa: E731
    return f"2.{b64(iv)}|{b64(ct)}|{b64(mac)}"
