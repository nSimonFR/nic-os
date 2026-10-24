"""Death Plan Switch → Vaultwarden Emergency Access.

One generic grantee account holds View access to the owner's vault. Only this
bridge knows its password until the switch fires. Then it:

  1. requests Emergency Access as that account (the owner gets Vaultwarden's
     email and can still reject during the wait);
  2. rotates the account's password, so nothing that existed before the firing
     still opens it;
  3. hands the new password to each contact the switch writes to: inside the
     switch's own message through its {vault_access} placeholder (the `access`
     hook, see pkgs/services/death-plan-switch-vault-access.patch), or in a
     separate mail when that message did not carry it.

If the owner checks in after a firing, the password is rotated again so the
copy the contacts received stops working. Rejecting the request itself stays
the owner's job, in Vaultwarden.

`run` is the 5-min timer, `access <contact-id>` the switch's hook, `check`
the daily health check (non-zero = the failed-unit alert), `seed` reads the
initial password on stdin.
"""

import fcntl
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

from ..httpjson import http_json, post_form
from ..logs import logger
from ..secrets import env_str
from ..state import load_json, save_json
from . import bwcrypto

TAG = "dps-ea-bridge"

# A fixed device id: Vaultwarden mails the account on every NEW device login.
DEVICE_ID = "7601bdaa-3f02-4bec-8176-7d8c52d90a05"
DEVICE_TYPE_LINUX_CLI = "25"

EA_CONFIRMED, EA_INITIATED, EA_APPROVED = 2, 3, 4

# No 0/O/1/l/I: the contacts type it by hand.
ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"


class VaultError(Exception):
    pass


class Config:
    switch_dir = "/mnt/data/death-plan-switch"
    state_dir = "/var/lib/dps-ea-bridge"
    vault_url = "http://127.0.0.1:8222/vaultwarden"
    public_url = ""
    grantee = ""
    grantor = ""
    dry_run = True

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    @classmethod
    def from_env(cls, env=None):
        return cls(
            switch_dir=env_str("SWITCH_DIR", cls.switch_dir, env),
            state_dir=env_str("STATE_DIR", cls.state_dir, env),
            vault_url=env_str("VAULT_URL", cls.vault_url, env).rstrip("/"),
            public_url=env_str("PUBLIC_URL", "", env),
            grantee=env_str("GRANTEE_EMAIL", "", env).strip().lower(),
            grantor=env_str("GRANTOR_EMAIL", "", env).strip().lower(),
            dry_run=env_str("DRY_RUN", "1", env) != "0",
        )

    @property
    def state_path(self):
        return os.path.join(self.state_dir, "state.json")


def new_password(rand=secrets.choice):
    return "-".join("".join(rand(ALPHABET) for _ in range(5)) for _ in range(5))


# ── Vaultwarden API ──────────────────────────────────────────────────────────

class Vault:
    def __init__(self, cfg, opener=None):
        self.cfg = cfg
        self.opener = opener

    def _call(self, method, path, token=None, payload=None):
        headers = {"Accept": "application/json"}
        data = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(payload).encode()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(self.cfg.vault_url + path, data=data,
                                     headers=headers, method=method)
        try:
            return http_json(req, timeout=60, opener=self.opener)
        except urllib.error.HTTPError as e:
            raise VaultError(f"{method} {path}: HTTP {e.code}") from None

    def prelogin(self, email):
        r = self._call("POST", "/identity/accounts/prelogin", payload={"email": email})
        return {"type": r["kdf"], "iterations": r["kdfIterations"],
                "memory": r.get("kdfMemory"), "parallelism": r.get("kdfParallelism")}

    def login(self, email, password):
        """A Session, with the user key already unwrapped (proves the crypto)."""
        kdf = self.prelogin(email)
        mkey = bwcrypto.master_key(password, email, kdf)
        phash = bwcrypto.password_hash(mkey, password)
        try:
            r = post_form(self.cfg.vault_url + "/identity/connect/token", {
                "grant_type": "password",
                "username": email,
                "password": phash,
                "scope": "api offline_access",
                "client_id": "cli",
                "device_identifier": DEVICE_ID,
                "device_name": TAG,
                "device_type": DEVICE_TYPE_LINUX_CLI,
            }, timeout=60, opener=self.opener)
        except urllib.error.HTTPError as e:
            raise VaultError(f"login as {email}: HTTP {e.code}") from None
        user_key = bwcrypto.decrypt(r["Key"], *bwcrypto.stretch(mkey))
        return Session(self, email, kdf, phash, r["access_token"], user_key)


class Session:
    def __init__(self, vault, email, kdf, phash, token, user_key):
        self.vault, self.email, self.kdf = vault, email, kdf
        self.phash, self.token, self.user_key = phash, token, user_key

    def granted(self):
        return self.vault._call("GET", "/api/emergency-access/granted", self.token)["data"]

    def initiate(self, ea_id):
        return self.vault._call("POST", f"/api/emergency-access/{ea_id}/initiate", self.token)

    def devices(self):
        return self.vault._call("GET", "/api/devices", self.token)["data"]

    def ciphers(self):
        return self.vault._call("GET", "/api/ciphers", self.token)["data"]

    def change_password(self, new):
        mkey = bwcrypto.master_key(new, self.email, self.kdf)
        self.vault._call("POST", "/api/accounts/password", self.token, {
            "masterPasswordHash": self.phash,
            "newMasterPasswordHash": bwcrypto.password_hash(mkey, new),
            "masterPasswordHint": None,
            "key": bwcrypto.encrypt(self.user_key, *bwcrypto.stretch(mkey)),
        })


def find_grant(session, grantor):
    for ea in session.granted():
        if (ea.get("email") or "").lower() == grantor:
            return ea
    raise VaultError(f"no Emergency Access from {grantor} on {session.email}")


# ── state ────────────────────────────────────────────────────────────────────

def load_state(cfg):
    return load_json(cfg.state_path, {"password": None, "pending": None, "fire": None})


def login_any(vault, cfg, state, save):
    """Log in with the current password, else with a rotation left half-done."""
    if not state.get("password"):
        raise VaultError("no password stored: run `dps-ea-bridge seed`")
    try:
        return vault.login(cfg.grantee, state["password"])
    except VaultError:
        if not state.get("pending"):
            raise
    s = vault.login(cfg.grantee, state["pending"])
    state["password"], state["pending"] = state["pending"], None
    save(state)
    return s


def rotate(vault, cfg, state, save, gen=new_password):
    session = login_any(vault, cfg, state, save)
    new = gen()
    # Persisted before the server sees it, so a crash mid-call loses nothing.
    state["pending"] = new
    save(state)
    session.change_password(new)
    state["password"], state["pending"] = new, None
    save(state)
    vault.login(cfg.grantee, new)
    return new


# ── mail ─────────────────────────────────────────────────────────────────────

def smtp_sender(smtp):
    """`send(to, subject, body)` over the switch's own SMTP settings."""
    import smtplib
    from email.message import EmailMessage

    def send(to, subject, body):
        msg = EmailMessage()
        msg["From"] = smtp["from_email"]
        msg["To"] = to
        msg["Subject"] = subject
        msg.set_content(body)
        cls = smtplib.SMTP_SSL if smtp.get("secure") == "ssl" else smtplib.SMTP
        with cls(smtp["host"], int(smtp["port"]), timeout=60) as s:
            if smtp.get("secure") == "tls":
                s.starttls()
            if smtp.get("user"):
                s.login(smtp["user"], smtp["pass"])
            s.send_message(msg)

    return send


def access_mail(contact, owner, cfg, password, opens_at, tz):
    when = datetime.fromtimestamp(opens_at, ZoneInfo(tz)).strftime("%d/%m/%Y %H:%M")
    name = contact.get("name") or ""
    subject = f"Accès au coffre de mots de passe de {owner} / Access to {owner}'s password vault"
    body = f"""Bonjour {name},

Suite au message de Death Plan Switch, voici l'accès au coffre de mots de passe de {owner}.
Il s'ouvre automatiquement à partir du {when} ({tz}). Avant cette date, la connexion
fonctionne mais le coffre n'apparaît pas encore.

  1. Ouvrez {cfg.public_url} dans un navigateur.
  2. Adresse e-mail : {cfg.grantee}
     Mot de passe : {password}
  3. Menu « Accès d'urgence », puis « Afficher » sur le coffre de {owner}.

Ne partagez ce mot de passe qu'avec les autres personnes de confiance.

---

Hello {name},

Following Death Plan Switch's message, here is access to {owner}'s password vault.
It opens automatically from {when} ({tz}). Until then you can log in, but the vault
will not show yet.

  1. Open {cfg.public_url} in a web browser.
  2. Email address: {cfg.grantee}
     Master password: {password}
  3. Go to "Emergency access", then "View" on {owner}'s vault.

Only share this password with the other people {owner} trusted.
"""
    return subject, body


def access_block(cfg, password, opens_at, tz):
    when = datetime.fromtimestamp(opens_at, ZoneInfo(tz)).strftime("%d/%m/%Y %H:%M")
    return (f"{cfg.public_url}\n"
            f"Identifiant / Login : {cfg.grantee}\n"
            f"Mot de passe / Password : {password}\n"
            f"Ouverture / Opens : {when} ({tz})")


# ── commands ─────────────────────────────────────────────────────────────────

def read_cycle(cfg):
    switch = load_json(os.path.join(cfg.switch_dir, "state.json"), None)
    if switch is None:
        raise VaultError(f"cannot read the switch state in {cfg.switch_dir}")
    return switch.get("cycle") or {}


def switch_config(cfg):
    config = load_json(os.path.join(cfg.switch_dir, "config.json"), {})
    return config.get("owner_name") or "the owner", config.get("timezone") or "UTC"


def prepare(cfg, vault, state, cycle, log, save, now=time.time):
    """Request access and rotate, once per firing. None in dry run."""
    fire = state.get("fire")
    if fire is None or fire.get("fired_at") != cycle.get("fired_at"):
        fire = {"fired_at": cycle.get("fired_at"), "opens_at": None,
                "rotated": False, "inline": [], "mailed": []}
        state["fire"] = fire

    if fire["opens_at"] is None:
        session = login_any(vault, cfg, state, save)
        ea = find_grant(session, cfg.grantor)
        if ea["status"] == EA_CONFIRMED:
            log(f"switch fired: requesting Emergency Access ({ea['waitTimeDays']}-day wait)")
            if cfg.dry_run:
                return None
            session.initiate(ea["id"])
        elif ea["status"] not in (EA_INITIATED, EA_APPROVED):
            raise VaultError(f"Emergency Access is in status {ea['status']}, cannot request it")
        fire["opens_at"] = int(now()) + int(ea["waitTimeDays"]) * 86400
        save(state)

    if not fire["rotated"]:
        if cfg.dry_run:
            log("would rotate the password")
            return None
        rotate(vault, cfg, state, save)
        fire["rotated"] = True
        save(state)
        log("password rotated")
    return fire


def run(cfg, vault, send, log, save, now=time.time):
    cycle = read_cycle(cfg)
    state = load_state(cfg)

    if cycle.get("stage") != "fired":
        if state.get("fire") is None:
            return 0
        log("the switch was reset after a firing: rotating the password the contacts got")
        if not cfg.dry_run:
            rotate(vault, cfg, state, save)
            state["fire"] = None
            save(state)
        return 0

    fire = prepare(cfg, vault, state, cycle, log, save, now)
    if fire is None:
        return 0

    # Contacts whose switch message carried {vault_access} already have it.
    owner, tz = switch_config(cfg)
    contacts = load_json(os.path.join(cfg.switch_dir, "contacts.json"), {}).get("contacts", [])
    for c in contacts:
        if c.get("id") not in (cycle.get("notified") or {}):
            continue
        if c["id"] in fire["inline"] or c["id"] in fire["mailed"]:
            continue
        send(c["email"], *access_mail(c, owner, cfg, state["password"], fire["opens_at"], tz))
        fire["mailed"].append(c["id"])
        save(state)
        log(f"sent the vault access to {c.get('name')}")
    return 0


def access(cfg, vault, log, save, contact_id, out, now=time.time):
    """The {vault_access} block for one contact's switch message, on stdout."""
    cycle = read_cycle(cfg)
    if cycle.get("stage") != "fired":
        raise VaultError("the switch has not fired")
    state = load_state(cfg)
    fire = prepare(cfg, vault, state, cycle, log, save, now)
    if fire is None:
        return 1
    _, tz = switch_config(cfg)
    out(access_block(cfg, state["password"], fire["opens_at"], tz))
    if contact_id not in fire["inline"]:
        fire["inline"].append(contact_id)
        save(state)
    return 0


def check(cfg, vault, log, save):
    """Problems as a list; empty = healthy."""
    if load_json(os.path.join(cfg.switch_dir, "state.json"), None) is None:
        return [f"cannot read the switch state in {cfg.switch_dir}"]
    state = load_state(cfg)
    try:
        session = login_any(vault, cfg, state, save)
        ea = find_grant(session, cfg.grantor)
    except (VaultError, ValueError) as e:
        return [str(e)]
    if state.get("fire"):
        return []
    problems = []
    if ea["status"] != EA_CONFIRMED:
        problems.append(f"Emergency Access is in status {ea['status']}, expected {EA_CONFIRMED} (confirmed)")
    others = [d.get("name") for d in session.devices() if d.get("identifier") != DEVICE_ID]
    if others:
        problems.append(f"{cfg.grantee} was logged in from other devices: {', '.join(map(str, others))}")
    if session.ciphers():
        problems.append(f"{cfg.grantee} has items in its own vault")
    return problems


def seed(cfg, vault, log, save, password):
    state = load_state(cfg)
    if state.get("password"):
        log("a password is already stored; refusing to overwrite it")
        return 1
    session = vault.login(cfg.grantee, password)
    ea = find_grant(session, cfg.grantor)
    state["password"] = password
    save(state)
    log(f"stored; Emergency Access from {cfg.grantor} is in status {ea['status']}")
    return 0


def main(argv=None, env=None, opener=None, send=None, log=None, stdin=None, out=None):
    argv = sys.argv[1:] if argv is None else argv
    cmd = argv[0] if argv else "run"
    cfg = Config.from_env(env)
    # `access` answers on stdout, so its log must not land there.
    log = log or logger(TAG, stream=(lambda: sys.stderr) if cmd == "access" else None)
    if not (cfg.grantee and cfg.grantor):
        log("FATAL GRANTEE_EMAIL and GRANTOR_EMAIL are required")
        return 2
    os.umask(0o077)
    vault = Vault(cfg, opener)

    def save(state):
        if not cfg.dry_run or cmd == "seed":
            save_json(cfg.state_path, state, indent=1)

    try:
        # The switch's hook and the timer can overlap; two rotations would race.
        with open(os.path.join(cfg.state_dir, "lock"), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return dispatch(cmd, argv, cfg, vault, send, log, save, stdin, out)
    except (VaultError, ValueError, OSError) as e:
        log(f"FATAL {e}")
        return 1


def dispatch(cmd, argv, cfg, vault, send, log, save, stdin, out):
    if cmd == "run":
        if send is None:
            smtp = load_json(os.path.join(cfg.switch_dir, "config.json"), {}).get("smtp")
            if not smtp:
                raise VaultError("no SMTP settings in the switch config")
            send = smtp_sender(smtp)
        return run(cfg, vault, send, log, save)
    if cmd == "access" and len(argv) == 2:
        return access(cfg, vault, log, save, argv[1], out or print)
    if cmd == "check":
        problems = check(cfg, vault, log, save)
        for p in problems:
            log(f"PROBLEM {p}")
        if not problems:
            log("healthy")
        return 1 if problems else 0
    if cmd == "seed":
        return seed(cfg, vault, log, save, (stdin or sys.stdin).readline().strip())
    log(f"unknown command {' '.join(argv)!r}; expected run, access <contact-id>, check or seed")
    return 2
