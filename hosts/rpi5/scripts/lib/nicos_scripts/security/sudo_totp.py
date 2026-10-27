"""sudo-totp-enroll: create the TOTP secret behind nsimon's sudo (hosts/rpi5/sudo-totp.nix).

Agents run as nsimon, so the secret lives where only root reads it, in
pam_google_authenticator's format, and reaches the user's phone once through
Vaultwarden's "Agents" org: the user clones it into their personal vault and
deletes it, then `vault-agent purge` empties the org's trash. Agents can read
that org, so the window lasts until the clone.

Run as root, once, by hand: `DRY_RUN=0 sudo-totp-enroll`
(no unit: the bot's password stays out of any permanent config). Refuses when a
secret exists: delete it first to re-enroll. Never prints or logs the secret.
"""

import base64
import os
import secrets
import sys
import urllib.parse

from ..logs import logger
from ..secrets import env_str, read_secret
from ..vaultwarden import agents
from ..vaultwarden.ea_bridge import Vault, VaultError

TAG = "sudo-totp-enroll"
ITEM = "rpi5 sudo (TOTP)"
# One-shot codes, 3 tries per 30 s, ±1 step of clock skew (a code lives ~90 s).
OPTIONS = ('" RATE_LIMIT 3 30', '" WINDOW_SIZE 3', '" DISALLOW_REUSE', '" TOTP_AUTH')


def new_secret(rand=secrets.token_bytes):
    return base64.b32encode(rand(20)).decode()


def secret_file(secret):
    """pam_google_authenticator's file: the secret, then its options."""
    return "\n".join((secret, *OPTIONS)) + "\n"


def otpauth(secret, user, host="rpi5"):
    label = urllib.parse.quote(f"{host} sudo:{user}")
    return f"otpauth://totp/{label}?secret={secret}&issuer={urllib.parse.quote(host + ' sudo')}"


def enroll(path, user, store, rand=secrets.token_bytes, log=print):
    """Write the secret to `path` (0600, created exclusively) and hand its
    otpauth URI to `store`; nothing is left behind if `store` fails."""
    if os.path.exists(path):
        log(f"{path} exists: delete it to re-enroll")
        return 3
    secret = new_secret(rand)
    tmp = f"{path}.new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(secret_file(secret))
        store(otpauth(secret, user))
        os.rename(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
    log(f"enrolled {user}: {ITEM!r} is in Vaultwarden's Agents org; clone it to your vault, then delete it")
    return 0


def vault_env(env=None):
    """vault-agent's settings, defaulting to vaultwarden.nix's wrapper values."""
    env = dict(os.environ if env is None else env)
    user = env.get("SUDO_TOTP_USER", "nsimon")
    env.setdefault("VAULT_AGENT_EMAIL", f"{user}+agents@pm.me")
    env.setdefault("VAULT_OWNER_EMAIL", f"{user}@pm.me")
    env.setdefault("VAULT_AGENT_PASSWORD_FILE", "/run/agenix/vaultwarden-agent-password")
    return env


def vault_store(env=None, opener=None):
    """The `store` that writes ITEM into the Agents org through vault-agent's bot."""
    env = vault_env(env)
    cfg = agents.Config(env)

    def store(uri):
        agent = agents.Agent(cfg, Vault(cfg, opener, device=(agents.DEVICE_ID, agents.TAG)),
                             read_secret(cfg.password_file))
        item = {"name": ITEM, "username": env_str("SUDO_TOTP_USER", "nsimon", env), "password": None,
                "uris": [], "totp": uri,
                "notes": "sudo on rpi5. Clone it to your personal vault, delete it here, "
                         "then have an agent run `vault-agent purge --name \"rpi5 sudo (TOTP)\"`."}
        result, rc = agents.add(agent, item, False, cfg.dry_run, lambda m: None)
        if rc:
            raise VaultError(f"{ITEM!r} already exists in the Agents org; delete and purge it first")
    return store


def main(env=None, opener=None, log=None):
    log = log or logger(TAG, stream=lambda: sys.stderr)
    user = env_str("SUDO_TOTP_USER", "nsimon", env)
    path = os.path.join(env_str("SUDO_TOTP_DIR", "/var/lib/sudo-totp", env), user)
    if env_str("DRY_RUN", "1", env) != "0":
        log(f"DRY_RUN: would create {path} and {ITEM!r}")
        return 0
    try:
        return enroll(path, user, vault_store(env, opener), log=log)
    except (VaultError, OSError, ValueError) as e:
        log(f"FATAL {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
