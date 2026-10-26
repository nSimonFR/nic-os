"""Agents → Vaultwarden: write logins into the "Agents" org.

A bot account owns the org and the owner is a confirmed member, so the owner's
master password never touches the Pi; the bot opens that org only. Bot and org
were set up once by hand (PR#815).

  add      create a login; --update replaces one of the same name, keeping
           the old password in its history
  list     names, usernames and URIs — never a secret
  purge    permanently delete an item already in the org's trash
  confirm  hand the org key to the owner once they accepted the invite
"""

import argparse
import json
import secrets
import string
import sys
from datetime import datetime, timezone

from ..logs import logger
from ..secrets import env_str, read_secret
from . import bwcrypto
from .ea_bridge import Vault, VaultError

TAG = "vault-agent"
# Fixed so Vaultwarden mails the bot's inbox once, not on every run.
DEVICE_ID = "3b7f0c52-9d41-4e8a-b6f2-1c0e5a7d9e34"
MEMBER_ACCEPTED = 1
ALPHABET = string.ascii_letters + string.digits + "-_.!"


class Config:
    def __init__(self, env=None):
        self.vault_url = env_str("VAULT_URL", "http://127.0.0.1:8222/vaultwarden", env).rstrip("/")
        self.email = env_str("VAULT_AGENT_EMAIL", "", env).strip().lower()
        self.password_file = env_str("VAULT_AGENT_PASSWORD_FILE", "", env)
        self.owner = env_str("VAULT_OWNER_EMAIL", "", env).strip().lower()
        self.org = self.collection = "Agents"
        self.dry_run = env_str("DRY_RUN", "1", env) != "0"


class Agent:
    """The bot's unlocked session and its view of the org."""

    def __init__(self, cfg, vault, password):
        self.session = vault.login(cfg.email, password)
        private = bwcrypto.decrypt(self.session.private_key, *bwcrypto.split(self.session.user_key))
        self.sync = self.call("GET", "/api/sync?excludeDomains=true")
        self.user_id = self.sync["profile"]["id"]
        org = next((o for o in self.sync["profile"].get("organizations", []) if o["name"] == cfg.org), None)
        if not org:
            raise VaultError(f"the bot is not in org {cfg.org!r}")
        self.org_id, self.key = org["id"], bwcrypto.rsa_decrypt(org["key"], private)
        self.collection_id = next((c["id"] for c in self.sync.get("collections", [])
                                   if c["organizationId"] == self.org_id
                                   and self.dec(c["name"]) == cfg.collection), None)
        if not self.collection_id:
            raise VaultError(f"no collection {cfg.collection!r} in org {cfg.org!r}")

    def call(self, method, path, payload=None):
        return self.session.vault._call(method, path, self.session.token, payload)

    def enc(self, text):
        return bwcrypto.encrypt(text.encode(), *bwcrypto.split(self.key)) if text else None

    def dec(self, encstring):
        return bwcrypto.decrypt(encstring, *bwcrypto.split(self.key)).decode() if encstring else None

    def items(self):
        return [c for c in self.sync.get("ciphers", [])
                if self.collection_id in (c.get("collectionIds") or []) and not c.get("deletedDate")]


def add(agent, item, update, dry_run, log):
    found = [c for c in agent.items() if agent.dec(c["name"]) == item["name"]]
    if len(found) > 1:
        raise VaultError(f"{len(found)} items are named {item['name']!r}; fix it in the web vault")
    old = found[0] if found else None
    if old and not update:
        log(f"{item['name']!r} already exists ({old['id']}); pass --update to replace it")
        return None, 3
    history = list((old or {}).get("passwordHistory") or [])
    old_pw = ((old or {}).get("login") or {}).get("password")
    if old_pw and agent.dec(old_pw) != item["password"]:
        now = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        history.append({"password": old_pw, "lastUsedDate": now})
    body = {
        "type": 1, "organizationId": agent.org_id, "encryptedFor": agent.user_id,
        "name": agent.enc(item["name"]), "notes": agent.enc(item["notes"]),
        "favorite": False, "reprompt": 0, "passwordHistory": history or None,
        "login": {"username": agent.enc(item["username"]), "password": agent.enc(item["password"]),
                  "uris": [{"uri": agent.enc(u), "match": None} for u in item["uris"]] or None,
                  "totp": agent.enc(item.get("totp"))},
    }
    action = "updated" if old else "created"
    if dry_run:
        log(f"DRY_RUN would have {action} {item['name']!r}")
        return {"action": "dry-run", "name": item["name"]}, 0
    if old:
        r = agent.call("PUT", f"/api/ciphers/{old['id']}", dict(body, lastKnownRevisionDate=old.get("revisionDate")))
    else:
        r = agent.call("POST", "/api/ciphers/create", {"cipher": body, "collectionIds": [agent.collection_id]})
    return {"action": action, "id": r["id"], "name": item["name"]}, 0


def purge(agent, name, dry_run, log):
    """Hard-delete the trashed items named `name`: the org keeps its trash 30
    days, readable by every member. Refuses while a live one remains."""
    named = [c for c in agent.sync.get("ciphers", [])
             if agent.collection_id in (c.get("collectionIds") or []) and agent.dec(c["name"]) == name]
    if any(not c.get("deletedDate") for c in named):
        log(f"{name!r} is still in the vault: delete it first")
        return 1
    if not named:
        log(f"nothing named {name!r} in the trash")
        return 1
    for c in named:
        log(f"{'DRY_RUN would purge' if dry_run else 'purging'} {name!r} ({c['id']})")
        if not dry_run:
            agent.call("DELETE", f"/api/ciphers/{c['id']}")
    return 0


def listing(agent):
    out = [{"id": c["id"], "name": agent.dec(c["name"]),
            "username": agent.dec((c.get("login") or {}).get("username")),
            "uris": [agent.dec(u["uri"]) for u in (c.get("login") or {}).get("uris") or []]}
           for c in agent.items()]
    return sorted(out, key=lambda i: i["name"].lower())


def confirm(agent, cfg, dry_run, log):
    """The configured owner only: anyone else who accepted stays unconfirmed."""
    members = agent.call("GET", f"/api/organizations/{agent.org_id}/users")["data"]
    m = next((m for m in members if m["email"].lower() == cfg.owner), None)
    if not m or m["status"] != MEMBER_ACCEPTED:
        log(f"{cfg.owner} has not accepted the invite (status {m and m['status']})")
        return 1
    log(f"confirming {cfg.owner}")
    if not dry_run:
        pub = agent.call("GET", f"/api/users/{m['userId']}/public-key")["publicKey"]
        agent.call("POST", f"/api/organizations/{agent.org_id}/users/{m['id']}/confirm",
                   {"key": bwcrypto.rsa_encrypt(agent.key, pub)})
    return 0


def parse(argv):
    p = argparse.ArgumentParser(prog=TAG, description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("--name", required=True)
    a.add_argument("--username")
    a.add_argument("--uri", action="append", default=[])
    a.add_argument("--notes")
    pw = a.add_mutually_exclusive_group(required=True)
    pw.add_argument("--password-file", help="'-' for stdin")
    pw.add_argument("--generate", nargs="?", type=int, const=24, metavar="LENGTH")
    a.add_argument("--update", action="store_true")
    sub.add_parser("list")
    sub.add_parser("purge").add_argument("--name", required=True)
    sub.add_parser("confirm")
    return p.parse_args(argv)


def main(argv=None, env=None, opener=None, log=None, stdin=None, out=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    cfg = Config(env)
    log = log or logger(TAG, stream=lambda: sys.stderr)
    out = out or print
    if not (cfg.email and cfg.password_file and cfg.owner):
        log("FATAL VAULT_AGENT_EMAIL, VAULT_AGENT_PASSWORD_FILE and VAULT_OWNER_EMAIL are required")
        return 2
    try:
        generated = None
        if args.cmd == "add":
            if args.password_file == "-":
                password = (stdin or sys.stdin).read().rstrip("\n")
            elif args.password_file:
                password = read_secret(args.password_file)
            else:
                password = generated = "".join(secrets.choice(ALPHABET) for _ in range(args.generate))
        agent = Agent(cfg, Vault(cfg, opener, device=(DEVICE_ID, TAG)), read_secret(cfg.password_file))
        if args.cmd == "list":
            out(json.dumps(listing(agent), indent=1))
            return 0
        if args.cmd == "confirm":
            return confirm(agent, cfg, cfg.dry_run, log)
        if args.cmd == "purge":
            return purge(agent, args.name, cfg.dry_run, log)
        item = {"name": args.name, "notes": args.notes, "username": args.username,
                "password": password, "uris": args.uri}
        result, rc = add(agent, item, args.update, cfg.dry_run, log)
        if result:
            out(json.dumps(dict(result, password=generated) if generated else result))
        return rc
    except (VaultError, ValueError, OSError) as e:
        log(f"FATAL {e}")
        return 1
