#!/usr/bin/env python3
"""
ryot-bootstrap: keep a working Ryot V2 API key on disk for the local services.

V1 passwords and API keys don't survive the V1→V2 migration, and V2 only mints
API keys for a signed-in user. With the admin token this gives the account a
password (stored root-only, so the user can read it and sign in), signs in and
creates a key. Consumers read `api-key` (raw) or `api.env` (RYOT_API_KEY=…).

A password reset deletes the user's API keys, so it resets only when the stored
password no longer signs in. A run with a working key does nothing.

Config via environment:
  RYOT_URL                   V2 base                (default http://127.0.0.1:13350)
  RYOT_FRONTEND_URL          public origin, sent as Origin to Better Auth   [required]
  SERVER_ADMIN_ACCESS_TOKEN  V2 admin token                                 [required]
  RYOT_EMAIL                 account to bootstrap   (default nsimon@ryot.local)
  RYOT_DB                    database for the user-id lookup (default ryotv2)
  SECRETS_DIR                output directory       (default /var/lib/ryot-v2/secrets)
  SECRETS_GROUP              group allowed to read the key (default ryot-api)
"""

import grp
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from ..logs import logger
from ..pg import psql_rows
from ..secrets import env_str, missing_env

log = logger("ryot-bootstrap")

REQUIRED_ENV = ("RYOT_FRONTEND_URL", "SERVER_ADMIN_ACCESS_TOKEN")
KEY_NAME = "nic-os services"
TIMEOUT = 240
# V2 listens only after its startup migration: ~1 min on the first boot after
# the V1 copy, seconds otherwise.
READY_WAIT_S = 900


@dataclass(frozen=True)
class Config:
    url: str = "http://127.0.0.1:13350"
    frontend_url: str = ""
    admin_token: str = ""
    email: str = "nsimon@ryot.local"
    db: str = "ryotv2"
    secrets_dir: str = "/var/lib/ryot-v2/secrets"
    secrets_group: str = "ryot-api"

    @classmethod
    def from_env(cls, env=None):
        return cls(
            url=env_str("RYOT_URL", cls.url, env).rstrip("/"),
            frontend_url=env_str("RYOT_FRONTEND_URL", "", env).rstrip("/"),
            admin_token=env_str("SERVER_ADMIN_ACCESS_TOKEN", "", env),
            email=env_str("RYOT_EMAIL", cls.email, env),
            db=env_str("RYOT_DB", cls.db, env),
            secrets_dir=env_str("SECRETS_DIR", cls.secrets_dir, env),
            secrets_group=env_str("SECRETS_GROUP", cls.secrets_group, env),
        )

    @property
    def key_file(self):
        return Path(self.secrets_dir) / "api-key"

    @property
    def env_file(self):
        return Path(self.secrets_dir) / "api.env"

    @property
    def password_file(self):
        return Path(self.secrets_dir) / "password"


def request(cfg, method, path, body=None, headers=None, opener=None):
    """(status, parsed body, response headers). HTTP errors are statuses."""
    hdrs = {"Content-Type": "application/json", "Origin": cfg.frontend_url}
    hdrs.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(cfg.url + path, data=data, headers=hdrs, method=method)
    try:
        with (opener or urllib.request.urlopen)(req, timeout=TIMEOUT) as resp:
            status, raw, rh = resp.status, resp.read(), getattr(resp, "headers", {})
    except urllib.error.HTTPError as e:
        status, raw, rh = e.code, e.read(), e.headers or {}
    try:
        parsed = json.loads(raw) if raw else {}
    except ValueError:
        parsed = {}
    return status, parsed, rh


def wait_ready(cfg, opener=None, sleep=time.sleep, budget=READY_WAIT_S, step=10):
    for _ in range(max(1, budget // step)):
        try:
            if request(cfg, "GET", "/api/system/health", opener=opener)[0] == 200:
                return True
        except (urllib.error.URLError, OSError):
            pass
        sleep(step)
    return False


def key_works(cfg, key, opener=None):
    # An empty RyotQL document passes auth and fails validation (400); a bad key is 401.
    status, _, _ = request(cfg, "POST", "/api/ryotql/execute", {"queries": {}},
                           {"X-Api-Key": key}, opener=opener)
    return status != 401


def session_cookie(headers):
    """The Better Auth session cookie from a sign-in response, as `name=value`."""
    values = headers.get_all("Set-Cookie") if hasattr(headers, "get_all") else \
        [headers.get("Set-Cookie", "")]
    for value in values or []:
        pair = (value or "").split(";", 1)[0]
        if "session_token=" in pair:
            return pair
    return None


def sign_in(cfg, password, opener=None):
    status, _, headers = request(cfg, "POST", "/api/auth/sign-in/email",
                                 {"email": cfg.email, "password": password}, opener=opener)
    return session_cookie(headers) if status == 200 else None


def reset_password(cfg, user_id, password, opener=None):
    status, body, _ = request(cfg, "POST", f"/api/instance-admin/users/{user_id}/reset-password",
                              {}, {"Admin-Access-Token": cfg.admin_token}, opener=opener)
    if status != 200 or "resetUrl" not in body:
        raise RuntimeError(f"admin reset-password failed ({status})")
    query = urllib.parse.urlparse(body["resetUrl"]).query
    token = urllib.parse.parse_qs(query).get("token", [""])[0]
    status, _, _ = request(cfg, "POST", "/api/auth/reset-password",
                           {"newPassword": password, "token": token}, opener=opener)
    if status != 200:
        raise RuntimeError(f"reset-password failed ({status})")


def create_key(cfg, cookie, opener=None):
    status, body, _ = request(cfg, "POST", "/api/auth/api-key/create", {"name": KEY_NAME},
                              {"Cookie": cookie}, opener=opener)
    if status != 200 or not body.get("key"):
        raise RuntimeError(f"api-key create failed ({status})")
    return body["key"]


def user_id_for(cfg, run):
    email = cfg.email.replace("'", "''")
    rows = psql_rows(run, f"SELECT id FROM \"user\" WHERE email = '{email}';", cfg.db)
    if not rows:
        raise RuntimeError(f"no Ryot user {cfg.email}")
    return rows[0][0]


def write_secret(path, text, group=None, mode=0o600):
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w") as f:
        os.fchmod(f.fileno(), mode)
        f.write(text)
    if group:
        os.chown(tmp, -1, grp.getgrnam(group).gr_gid)
    os.replace(tmp, path)


def ensure_key(cfg, run, opener=None, new_password=None, write=write_secret):
    if cfg.key_file.exists() and key_works(cfg, cfg.key_file.read_text().strip(), opener):
        log("API key works — nothing to do")
        return "kept"

    cookie = None
    if cfg.password_file.exists():
        cookie = sign_in(cfg, cfg.password_file.read_text().strip(), opener)
    if cookie is None:
        password = new_password or secrets.token_urlsafe(24)
        reset_password(cfg, user_id_for(cfg, run), password, opener)
        write(cfg.password_file, password + "\n")
        cookie = sign_in(cfg, password, opener)
        if cookie is None:
            raise RuntimeError("sign-in failed right after the password reset")
        log(f"password set for {cfg.email} (stored in {cfg.password_file})")

    key = create_key(cfg, cookie, opener)
    write(cfg.key_file, key + "\n", cfg.secrets_group, 0o640)
    write(cfg.env_file, f"RYOT_API_KEY={key}\n", cfg.secrets_group, 0o640)
    log(f"new API key written to {cfg.key_file}")
    return "created"


def _run(argv):
    return subprocess.run(argv, check=True, capture_output=True, text=True).stdout


def main(env=None, run=_run, opener=None, sleep=time.sleep):
    cfg = Config.from_env(env)
    missing = missing_env(REQUIRED_ENV, env)
    if missing:
        log(f"FATAL: missing env: {', '.join(missing)}")
        return 1
    Path(cfg.secrets_dir).mkdir(mode=0o750, parents=True, exist_ok=True)
    if not wait_ready(cfg, opener=opener, sleep=sleep):
        log(f"FATAL: Ryot not healthy at {cfg.url} after {READY_WAIT_S}s")
        return 1
    try:
        ensure_key(cfg, run, opener=opener)
    except (RuntimeError, urllib.error.URLError, OSError) as e:
        log(f"FATAL: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
