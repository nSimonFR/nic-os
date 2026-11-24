"""Sync the OIDC clients declared in `nic.sso.clients` into Pocket ID.

hosts/rpi5/security/pocket-id.nix writes the declarations to a JSON file; this
upserts each one through the admin API (STATIC_API_KEY) and keeps its secret in
`secretFile`, readable by the consuming service's group.

A client's secret is the content of `secretFile`; `idFile` (kept in a separate
directory, since client ids may contain dots) records the Pocket ID secret id it
was registered under. The value is (re)registered whenever that id
is not among the client's active secrets: a missing file (a new random value), a
recreated client, or a registration interrupted on an earlier run. A restored or
reset database so gets back the secrets the services already hold.

When a client declares `allowedGroups` (Pocket ID group names), it is marked
group-restricted and its allowed user groups are set to exactly those; without
it the restriction is left as it is (an unrestricted client's groups grant
nothing, and Pocket ID drops them on any update). The flag is what Pocket ID checks: an
unrestricted client lets every user in whatever groups it lists, and any update
that leaves the flag off clears those groups.

Clients that exist in Pocket ID but are not declared are left alone.
"""

import json
import os
import secrets
import shutil
import time
import urllib.error
import urllib.request
from pathlib import Path

from ..httpjson import http_json
from ..logs import logger
from ..secrets import env_str

TAG = "pocket-id-clients"


class Config:
    def __init__(self, url, api_key, clients_file):
        self.url = url.rstrip("/")
        self.api_key = api_key
        self.clients_file = clients_file

    @classmethod
    def from_env(cls, env=None):
        return cls(
            url=env_str("POCKET_ID_URL", "http://127.0.0.1:1411", env),
            api_key=env_str("STATIC_API_KEY", "", env),
            clients_file=env_str("CLIENTS_FILE", "", env),
        )


class Api:
    def __init__(self, cfg, opener=None):
        self.cfg = cfg
        self.opener = opener

    def call(self, method, path, body=None):
        req = urllib.request.Request(
            f"{self.cfg.url}{path}",
            data=None if body is None else json.dumps(body).encode(),
            headers={"X-API-Key": self.cfg.api_key, "Content-Type": "application/json"},
            method=method,
        )
        return http_json(req, opener=self.opener)

    def get_client(self, client_id):
        try:
            return self.call("GET", f"/api/oidc/clients/{client_id}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise


def wait_ready(api, sleep=time.sleep, tries=60):
    for _ in range(tries):
        try:
            api.call("GET", "/healthz")
            return
        except (urllib.error.URLError, ConnectionError, OSError):
            sleep(1)
    raise RuntimeError("Pocket ID did not answer /healthz")


def desired(c):
    """The client fields this script owns; the rest (logo, groups) is kept."""
    want = {
        "name": c["name"],
        "callbackURLs": c["callbackURLs"],
        "logoutCallbackURLs": c.get("logoutCallbackURLs", []),
        "launchURL": c.get("launchURL"),
        "isPublic": c.get("isPublic", False),
        "pkceEnabled": c.get("pkceEnabled", False),
        "skipConsent": True,
    }
    if c.get("allowedGroups") is not None:
        want["isGroupRestricted"] = True
    return want


def write_secret(path, value, group, chown=shutil.chown):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + "~")  # "~" is not valid in a client id
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o440)
    with os.fdopen(fd, "w") as f:
        f.write(value)
    chown(tmp, user="root", group=group)
    os.chmod(tmp, 0o440)
    tmp.replace(path)


def active_ids(secrets_list):
    return {sec["id"] for sec in secrets_list or [] if sec.get("isActive", True)}


def sync_client(api, c, log, chown=shutil.chown):
    cid = c["id"]
    want = desired(c)
    current = api.get_client(cid)
    if current is None:
        api.call("POST", "/api/oidc/clients", {"id": cid, **want})
        log(f"{cid}: created")
    else:
        merged = {**current, **want}
        if any(current.get(k) != merged[k] for k in want):
            api.call("PUT", f"/api/oidc/clients/{cid}", merged)
            log(f"{cid}: updated")

    sync_groups(api, c, current, log)
    if want["isPublic"]:
        return
    sync_secret(api, c, current, log, chown=chown)
    write_env(c, chown=chown)


def group_ids(api, names):
    listed = api.call("GET", "/api/user-groups?pagination%5Blimit%5D=100")["data"]
    by_name = {g["name"]: g["id"] for g in listed}
    missing = [n for n in names if n not in by_name]
    if missing:
        raise LookupError(f"unknown Pocket ID group(s): {', '.join(missing)}")
    return sorted(by_name[n] for n in names)


def sync_groups(api, c, current, log):
    names = c.get("allowedGroups")
    if names is None:
        return
    cid = c["id"]
    want = group_ids(api, names)
    have = sorted(g["id"] for g in (current or {}).get("allowedUserGroups") or [])
    if want != have:
        api.call(
            "PUT",
            f"/api/oidc/clients/{cid}/allowed-user-groups",
            {"userGroupIds": want},
        )
        log(f"{cid}: allowed groups set to {', '.join(sorted(names)) or 'none'}")


def sync_secret(api, c, current, log, chown=shutil.chown):
    cid = c["id"]
    path = Path(c["secretFile"])
    id_file = Path(c["idFile"])
    existing = path.read_text().strip() if path.exists() else ""
    if existing and current is not None and id_file.exists():
        listed = api.call("GET", f"/api/oidc/clients/{cid}/secrets")
        if id_file.read_text().strip() in active_ids(listed):
            return
    value = existing or secrets.token_urlsafe(32)
    reg = api.call("POST", f"/api/oidc/clients/{cid}/secrets", {"secret": value})
    if not existing:
        write_secret(path, value, c["secretGroup"], chown=chown)
    id_file.parent.mkdir(parents=True, exist_ok=True)
    id_file.write_text(reg["id"])
    log(f"{cid}: secret registered")


def write_env(c, chown=shutil.chown):
    """`<envVar>=<secret>` for apps that only read the secret from the env."""
    var = c.get("envVar")
    if not var:
        return
    line = f"{var}={Path(c['secretFile']).read_text().strip()}\n"
    env = Path(c["envFile"])
    if not env.exists() or env.read_text() != line:
        write_secret(env, line, c["secretGroup"], chown=chown)


def main(env=None, opener=None, sleep=time.sleep, chown=shutil.chown, log=None):
    log = log or logger(TAG)
    cfg = Config.from_env(env)
    if not cfg.api_key or not cfg.clients_file:
        log("FATAL: STATIC_API_KEY and CLIENTS_FILE are required")
        return 1
    clients = json.loads(Path(cfg.clients_file).read_text())
    api = Api(cfg, opener=opener)
    wait_ready(api, sleep=sleep)
    failed = 0
    for c in clients:
        try:
            sync_client(api, c, log, chown=chown)
        except (urllib.error.URLError, OSError, ValueError, LookupError) as e:
            log(f"{c.get('id', '<missing id>')}: {e}")
            failed += 1
    return 1 if failed else 0
