"""Agents → Vaultwarden: write logins into a shared org collection.

A bot account owns the "Agents" org and the owner is a confirmed member, so what
the bot writes shows up in the owner's vault while the owner's master password
never touches the Pi. The bot's password only opens that org.

  add      create a login or note (`--update` replaces one of the same name,
           keeping the old password in its history)
  list     names, usernames and URIs in the collection — never a secret
  init     create the org + collection, invite the owner
  confirm  hand the org key to the owner once they accepted the invite
"""

import argparse
import json
import os
import secrets
import string
import sys
import urllib.parse
from datetime import datetime, timezone

from ..logs import logger
from ..secrets import env_str, read_secret
from . import bwcrypto
from .ea_bridge import Vault, VaultError

TAG = "vault-agent"

# Fixed so Vaultwarden mails the bot's inbox once, not on every run.
DEVICE_ID = "3b7f0c52-9d41-4e8a-b6f2-1c0e5a7d9e34"

LOGIN, NOTE = 1, 2
OWNER = 0
MEMBER_ACCEPTED = 1

ALPHABET = string.ascii_letters + string.digits + "-_.!"


class Config:
    vault_url = "http://127.0.0.1:8222/vaultwarden"
    email = ""
    password_file = ""
    owner = ""
    org = "Agents"
    collection = "Agents"
    dry_run = True

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    @classmethod
    def from_env(cls, env=None):
        return cls(
            vault_url=env_str("VAULT_URL", cls.vault_url, env).rstrip("/"),
            email=env_str("VAULT_AGENT_EMAIL", "", env).strip().lower(),
            password_file=env_str("VAULT_AGENT_PASSWORD_FILE", "", env),
            owner=env_str("VAULT_OWNER_EMAIL", "", env).strip().lower(),
            org=env_str("VAULT_AGENT_ORG", cls.org, env),
            collection=env_str("VAULT_AGENT_COLLECTION", cls.collection, env),
            dry_run=env_str("DRY_RUN", "1", env) != "0",
        )


def new_password(length=24, rand=secrets.choice):
    return "".join(rand(ALPHABET) for _ in range(length))


class Agent:
    """The bot's unlocked session plus its view of the org."""

    def __init__(self, cfg, vault, password):
        self.cfg = cfg
        self.session = vault.login(cfg.email, password)
        self.private_der = bwcrypto.decrypt(self.session.private_key,
                                            *bwcrypto.split(self.session.user_key))
        self.refresh()

    def call(self, method, path, payload=None):
        return self.session.vault._call(method, path, self.session.token, payload)

    def refresh(self):
        self.sync = self.call("GET", "/api/sync?excludeDomains=true")
        self.user_id = self.sync["profile"]["id"]
        self.org_id = self.org_key = self.collection_id = None
        for o in self.sync["profile"].get("organizations", []):
            if o["name"] == self.cfg.org:
                self.org_id = o["id"]
                self.org_key = bwcrypto.rsa_decrypt(o["key"], self.private_der)
        for c in self.sync.get("collections", []):
            if c["organizationId"] == self.org_id and self.dec(c["name"]) == self.cfg.collection:
                self.collection_id = c["id"]

    def require_org(self):
        if not self.collection_id:
            raise VaultError(f"no collection {self.cfg.collection!r} in org {self.cfg.org!r}: run init")

    def enc(self, text):
        return bwcrypto.encrypt(text.encode(), *bwcrypto.split(self.org_key)) if text else None

    def dec(self, encstring):
        return bwcrypto.decrypt(encstring, *bwcrypto.split(self.org_key)).decode() if encstring else None

    def items(self):
        for c in self.sync.get("ciphers", []):
            if self.collection_id in (c.get("collectionIds") or []) and not c.get("deletedDate"):
                yield c

    def find(self, name):
        return [c for c in self.items() if self.dec(c["name"]) == name]

    def public_key(self, user_id):
        return self.call("GET", f"/api/users/{user_id}/public-key")["publicKey"]

    def members(self):
        return self.call("GET", f"/api/organizations/{self.org_id}/users")["data"]


def cipher_payload(agent, item, old=None):
    body = {
        "type": item["type"],
        "organizationId": agent.org_id,
        "encryptedFor": agent.user_id,
        "name": agent.enc(item["name"]),
        "notes": agent.enc(item.get("notes")),
        "favorite": False,
        "reprompt": 0,
    }
    if item["type"] == NOTE:
        body["secureNote"] = {"type": 0}
        return body
    history = list((old or {}).get("passwordHistory") or [])
    old_pw = ((old or {}).get("login") or {}).get("password")
    if old_pw and agent.dec(old_pw) != item.get("password"):
        now = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        history.append({"password": old_pw, "lastUsedDate": now})
    body["passwordHistory"] = history or None
    body["login"] = {
        "username": agent.enc(item.get("username")),
        "password": agent.enc(item.get("password")),
        "totp": agent.enc(item.get("totp")),
        "uris": [{"uri": agent.enc(u), "match": None} for u in item.get("uris", [])] or None,
    }
    return body


def add(agent, item, update, dry_run, log):
    agent.require_org()
    found = agent.find(item["name"])
    if len(found) > 1:
        raise VaultError(f"{len(found)} items are named {item['name']!r}; fix it in the web vault")
    if found and not update:
        log(f"{item['name']!r} already exists ({found[0]['id']}); pass --update to replace it")
        return None, 3
    old = found[0] if found else None
    body = cipher_payload(agent, item, old)
    action = "updated" if old else "created"
    if dry_run:
        log(f"DRY_RUN would have {action} {item['name']!r}")
        return {"action": "dry-run", "name": item["name"]}, 0
    if old:
        r = agent.call("PUT", f"/api/ciphers/{old['id']}",
                       dict(body, lastKnownRevisionDate=old.get("revisionDate")))
    else:
        r = agent.call("POST", "/api/ciphers/create",
                       {"cipher": body, "collectionIds": [agent.collection_id]})
    return {"action": action, "id": r["id"], "name": item["name"]}, 0


def listing(agent):
    agent.require_org()
    out = []
    for c in agent.items():
        login = c.get("login") or {}
        out.append({
            "id": c["id"],
            "name": agent.dec(c["name"]),
            "username": agent.dec(login.get("username")),
            "uris": [agent.dec(u["uri"]) for u in login.get("uris") or []],
        })
    return sorted(out, key=lambda i: i["name"].lower())


def init(agent, cfg, dry_run, log):
    if not agent.org_id:
        org_key = os.urandom(64)
        public, private = bwcrypto.new_keypair(org_key)
        log(f"creating org {cfg.org!r} with collection {cfg.collection!r}")
        if dry_run:
            return 0
        agent.call("POST", "/api/organizations", {
            "name": cfg.org,
            "billingEmail": cfg.email,
            "collectionName": bwcrypto.encrypt(cfg.collection.encode(), *bwcrypto.split(org_key)),
            "key": bwcrypto.rsa_encrypt(org_key, agent.public_key(agent.user_id)),
            "keys": {"publicKey": public, "encryptedPrivateKey": private},
            "planType": 0,
        })
        agent.refresh()
    if any(m["email"].lower() == cfg.owner for m in agent.members()):
        log(f"{cfg.owner} is already a member")
        return 0
    log(f"inviting {cfg.owner} as owner; accept from the email, then run confirm")
    if not dry_run:
        agent.call("POST", f"/api/organizations/{agent.org_id}/users/invite", {
            "emails": [cfg.owner], "groups": [], "type": OWNER, "collections": [], "permissions": {},
        })
    return 0


def confirm(agent, cfg, dry_run, log):
    """Only the configured owner: anyone else who accepted stays unconfirmed."""
    if not agent.org_id:
        raise VaultError(f"no org {cfg.org!r}: run init")
    for m in agent.members():
        if m["email"].lower() != cfg.owner:
            continue
        if m["status"] != MEMBER_ACCEPTED:
            log(f"{cfg.owner} is in status {m['status']}; confirm needs 1 (accepted)")
            return 1
        log(f"confirming {cfg.owner}")
        if not dry_run:
            key = bwcrypto.rsa_encrypt(agent.org_key, agent.public_key(m["userId"]))
            agent.call("POST", f"/api/organizations/{agent.org_id}/users/{m['id']}/confirm", {"key": key})
        return 0
    log(f"{cfg.owner} is not invited: run init")
    return 1


def parse(argv):
    p = argparse.ArgumentParser(prog=TAG, description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add", help="create a login (or --note)")
    a.add_argument("--name", required=True)
    a.add_argument("--username")
    a.add_argument("--uri", action="append", default=[], help="repeatable")
    a.add_argument("--notes")
    a.add_argument("--totp", help="otpauth:// URI or base32 secret")
    a.add_argument("--note", action="store_true", help="a secure note instead of a login")
    pw = a.add_mutually_exclusive_group()
    pw.add_argument("--password-file", help="read the password from this file, '-' for stdin")
    pw.add_argument("--generate", nargs="?", type=int, const=24, metavar="LENGTH",
                    help="generate one and print it")
    a.add_argument("--update", action="store_true", help="replace an item of the same name")
    sub.add_parser("list")
    sub.add_parser("init")
    sub.add_parser("confirm")
    return p.parse_args(argv)


def item_from(args, stdin):
    generated = None
    if args.note:
        if args.username or args.uri or args.password_file or args.generate or args.totp:
            raise ValueError("--note takes only --name and --notes")
        return {"type": NOTE, "name": args.name, "notes": args.notes}, None
    password = None
    if args.password_file == "-":
        password = stdin.read().rstrip("\n")
    elif args.password_file:
        password = read_secret(args.password_file)
    elif args.generate:
        password = generated = new_password(args.generate)
    for u in args.uri:
        if not urllib.parse.urlparse(u).scheme:
            raise ValueError(f"--uri {u!r} needs a scheme (https://…)")
    return {"type": LOGIN, "name": args.name, "notes": args.notes, "username": args.username,
            "password": password, "uris": args.uri, "totp": args.totp}, generated


def main(argv=None, env=None, opener=None, log=None, stdin=None, out=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    cfg = Config.from_env(env)
    log = log or logger(TAG, stream=lambda: sys.stderr)
    out = out or print
    if not (cfg.email and cfg.password_file and cfg.owner):
        log("FATAL VAULT_AGENT_EMAIL, VAULT_AGENT_PASSWORD_FILE and VAULT_OWNER_EMAIL are required")
        return 2
    try:
        if args.cmd == "add":
            item, generated = item_from(args, stdin or sys.stdin)
        agent = Agent(cfg, Vault(cfg, opener, device=(DEVICE_ID, TAG)), read_secret(cfg.password_file))
        if args.cmd == "add":
            result, rc = add(agent, item, args.update, cfg.dry_run, log)
            if result:
                if generated:
                    result["password"] = generated
                out(json.dumps(result))
            return rc
        if args.cmd == "list":
            out(json.dumps(listing(agent), indent=1))
            return 0
        if args.cmd == "init":
            return init(agent, cfg, cfg.dry_run, log)
        return confirm(agent, cfg, cfg.dry_run, log)
    except (VaultError, ValueError, OSError) as e:
        log(f"FATAL {e}")
        return 1
