"""Sync the OIDC clients declared in `nic.sso.clients` into Pocket ID.

hosts/rpi5/security/pocket-id.nix writes the declarations to a JSON file; this
upserts each one through the admin API (STATIC_API_KEY) and keeps its secret in
`secretFile`, readable by the consuming service's group.

A client's secret is the file's content. It is (re)registered when the file is
missing (a new random value) or when the client had to be created, so a restored
or reset Pocket ID database gets the secrets the services already hold.

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

# Fields this script owns; everything else on the client (logo, groups) is kept.
MANAGED = (
    "name",
    "callbackURLs",
    "logoutCallbackURLs",
    "launchURL",
    "isPublic",
    "pkceEnabled",
    "skipConsent",
)


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
    return {
        "name": c["name"],
        "callbackURLs": c["callbackURLs"],
        "logoutCallbackURLs": c.get("logoutCallbackURLs", []),
        "launchURL": c.get("launchURL"),
        "isPublic": c.get("isPublic", False),
        "pkceEnabled": c.get("pkceEnabled", False),
        "skipConsent": True,
    }


def write_secret(path, value, group, chown=shutil.chown):
    path = Path(path)
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o440)
    with os.fdopen(fd, "w") as f:
        f.write(value)
    chown(tmp, user="root", group=group)
    os.chmod(tmp, 0o440)
    tmp.replace(path)


def sync_client(api, c, log, chown=shutil.chown):
    cid = c["id"]
    want = desired(c)
    current = api.get_client(cid)
    created = current is None
    if created:
        api.call("POST", "/api/oidc/clients", {"id": cid, **want})
        log(f"{cid}: created")
    else:
        merged = {**current, **want}
        if any(current.get(k) != merged[k] for k in MANAGED):
            api.call("PUT", f"/api/oidc/clients/{cid}", merged)
            log(f"{cid}: updated")

    if want["isPublic"]:
        return
    path = Path(c["secretFile"])
    existing = path.read_text().strip() if path.exists() else ""
    if existing and not created:
        return
    value = existing or secrets.token_urlsafe(32)
    api.call("POST", f"/api/oidc/clients/{cid}/secrets", {"secret": value})
    if not existing:
        write_secret(path, value, c["secretGroup"], chown=chown)
    log(f"{cid}: secret registered")


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
        except (urllib.error.URLError, OSError, ValueError) as e:
            log(f"{c['id']}: {e}")
            failed += 1
    return 1 if failed else 0
