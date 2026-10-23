#!/usr/bin/env python3
"""
agent-vault-bootstrap: converge Agent Vault on what the repo declares.

The vault's state is derived, never hand-edited: credentials come from the agenix
env file, services from the JSON hosts/rpi5/agent-vault.nix writes, the owner
account from its own agenix secret. Re-running is a no-op apart from re-setting
the same values, so a lost database is recovered by restarting the server.

Writes, into OUT_DIR (owned by whoever owns OUT_DIR):
  agent-token   the Hermes agent token (kept across runs while it still works)
  ca-bundle.pem the system roots plus the MITM root, for SSL_CERT_FILE & co.
  proxy.env     HTTPS_PROXY & co., plus KEY=__placeholder__ for every brokered key

Env:
  AGENT_VAULT_ADDR              http://127.0.0.1:14321
  AGENT_VAULT_PROXY             127.0.0.1:14322
  AGENT_VAULT_ADMIN_EMAIL       owner login
  AGENT_VAULT_ADMIN_PASSWORD_FILE
  AGENT_VAULT_CREDS_FILE        KEY=VALUE file holding the real credentials
  AGENT_VAULT_SERVICES_FILE     JSON: [{name, host, keys: [...], in: [...]}]
  AGENT_VAULT_OUT_DIR
  AGENT_VAULT_AGENT             hermes
  AGENT_VAULT_NO_PROXY          extra NO_PROXY hosts, comma-separated
  AGENT_VAULT_ON_TOKEN_CHANGE   command run when the token changed (restarts Hermes,
                                which only reads proxy.env at start)
  SYSTEM_CA_BUNDLE              /etc/ssl/certs/ca-certificates.crt
  AGENT_VAULT_BOOTSTRAP_APPLY   1 to write; anything else is a dry run
"""

import json
import os
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from ..logs import logger
from ..secrets import env_str, read_secret

log = logger("agent-vault-bootstrap")

VAULT = "default"  # the owner is granted admin on it at registration


@dataclass(frozen=True)
class Config:
    addr: str = "http://127.0.0.1:14321"
    proxy: str = "127.0.0.1:14322"
    admin_email: str = ""
    admin_password_file: str = ""
    creds_file: str = ""
    services_file: str = ""
    out_dir: str = ""
    agent: str = "hermes"
    no_proxy: str = ""
    on_token_change: str = ""
    system_ca_bundle: str = "/etc/ssl/certs/ca-certificates.crt"
    dry_run: bool = True

    @classmethod
    def from_env(cls, env=None):
        d = cls()
        return cls(
            addr=env_str("AGENT_VAULT_ADDR", d.addr, env).rstrip("/"),
            proxy=env_str("AGENT_VAULT_PROXY", d.proxy, env),
            admin_email=env_str("AGENT_VAULT_ADMIN_EMAIL", "", env),
            admin_password_file=env_str("AGENT_VAULT_ADMIN_PASSWORD_FILE", "", env),
            creds_file=env_str("AGENT_VAULT_CREDS_FILE", "", env),
            services_file=env_str("AGENT_VAULT_SERVICES_FILE", "", env),
            out_dir=env_str("AGENT_VAULT_OUT_DIR", "", env),
            agent=env_str("AGENT_VAULT_AGENT", d.agent, env),
            no_proxy=env_str("AGENT_VAULT_NO_PROXY", "", env),
            on_token_change=env_str("AGENT_VAULT_ON_TOKEN_CHANGE", "", env),
            system_ca_bundle=env_str("SYSTEM_CA_BUNDLE", d.system_ca_bundle, env),
            dry_run=env_str("AGENT_VAULT_BOOTSTRAP_APPLY", "", env) != "1",
        )


def placeholder(key):
    return f"__{key.lower()}__"


def parse_env_file(text):
    """KEY=VALUE lines → dict. Blank lines and comments skipped; no quoting rules."""
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value
    return out


def services_payload(declared):
    """The declared services as Agent Vault's broker.Service list.

    Passthrough auth plus placeholder substitution: the client keeps sending the
    key wherever it already does (header, query, JSON body) and the broker swaps
    the placeholder for the real value on the surfaces listed in `in` only.
    """
    return [
        {
            "name": s["name"],
            "host": s["host"],
            "auth": {"type": "passthrough"},
            "substitutions": [
                {"key": k, "placeholder": placeholder(k), "in": s["in"]}
                for k in s["keys"]
            ],
        }
        for s in declared
    ]


def brokered_keys(declared):
    return sorted({k for s in declared for k in s["keys"]})


def proxy_env(cfg, token, bundle_path, keys):
    proxy_url = f"http://{token}:{VAULT}@{cfg.proxy}"
    no_proxy = ",".join(
        h for h in ["localhost", "127.0.0.1", "::1", *cfg.no_proxy.split(",")] if h
    )
    lines = [
        f"HTTPS_PROXY={proxy_url}",
        f"HTTP_PROXY={proxy_url}",
        f"https_proxy={proxy_url}",
        f"http_proxy={proxy_url}",
        f"NO_PROXY={no_proxy}",
        f"no_proxy={no_proxy}",
        "NODE_USE_ENV_PROXY=1",
    ]
    for var in (
        "SSL_CERT_FILE",
        "REQUESTS_CA_BUNDLE",
        "CURL_CA_BUNDLE",
        "NODE_EXTRA_CA_CERTS",
        "GIT_SSL_CAINFO",
        "DENO_CERT",
    ):
        lines.append(f"{var}={bundle_path}")
    lines += [f"{k}={placeholder(k)}" for k in keys]
    return "\n".join(lines) + "\n"


class Api:
    """JSON calls against the management API. `opener` is the test seam."""

    def __init__(self, addr, opener=None):
        self.addr = addr
        self.opener = opener or urllib.request.urlopen

    def call(self, method, path, body=None, token=None, headers=None, raw=False):
        hdrs = dict(headers or {})
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            hdrs["Content-Type"] = "application/json"
        if token:
            hdrs["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(
            self.addr + path, data=data, headers=hdrs, method=method
        )
        try:
            with self.opener(req, timeout=30) as resp:
                status, text = resp.status, resp.read().decode()
        except urllib.error.HTTPError as e:
            status, text = e.code, e.read().decode(errors="replace")
        if raw:
            return status, text
        try:
            return status, json.loads(text) if text else {}
        except ValueError:
            return status, {"error": text}


def wait_healthy(api, tries=60, sleep=time.sleep):
    for _ in range(tries):
        try:
            status, _ = api.call("GET", "/health", raw=True)
            if status == 200:
                return True
        except OSError:
            pass
        sleep(1)
    return False


def owner_session(api, email, password):
    """Log in, registering the owner first on a fresh database."""
    creds = {"email": email, "password": password, "device_label": "bootstrap"}
    status, body = api.call("POST", "/v1/auth/login", creds)
    if status == 200 and body.get("token"):
        return body["token"]
    status, body = api.call("POST", "/v1/auth/register", creds)
    if status in (200, 201) and body.get("token"):
        log(f"registered owner {email}")
        return body["token"]
    raise RuntimeError(f"cannot log in or register owner ({status}: {body})")


def agent_token(api, session, name, existing):
    """Reuse `existing` while it still authenticates, else mint (or rotate) one."""
    if existing:
        status, _ = api.call(
            "GET", "/discover", token=existing, headers={"X-Vault": VAULT}
        )
        if status == 200:
            return existing, "kept"
    status, _ = api.call("GET", f"/v1/agents/{name}", token=session)
    if status == 200:
        status, body = api.call(
            "POST", f"/v1/agents/{name}/rotate", {}, token=session
        )
        action = "rotated"
    else:
        status, body = api.call(
            "POST",
            "/v1/agents",
            {"name": name, "vaults": [{"vault_name": VAULT, "vault_role": "proxy"}]},
            token=session,
        )
        action = "created"
    token = body.get("av_agent_token")
    if status not in (200, 201) or not token:
        raise RuntimeError(f"cannot mint agent token ({status}: {body})")
    return token, action


def expect(status, body, what):
    if status not in (200, 201, 204):
        raise RuntimeError(f"{what} failed ({status}: {body})")


def write_owned(path, text, mode):
    """Write `text` to `path` with `mode`, owned like its directory."""
    st = os.stat(path.parent)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def run(cfg, api, sleep=time.sleep, run_cmd=subprocess.run):
    if not (cfg.services_file and cfg.creds_file):
        raise RuntimeError("AGENT_VAULT_SERVICES_FILE and AGENT_VAULT_CREDS_FILE are required")
    declared = json.loads(Path(cfg.services_file).read_text())
    keys = brokered_keys(declared)
    creds = parse_env_file(Path(cfg.creds_file).read_text())
    missing = [k for k in keys if not creds.get(k)]
    if missing:
        raise RuntimeError(f"not in {cfg.creds_file}: {', '.join(missing)}")

    if cfg.dry_run:
        log(f"dry run — would broker {', '.join(keys)} across {len(declared)} services")
        return 0

    if not wait_healthy(api, sleep=sleep):
        raise RuntimeError(f"{cfg.addr}/health never answered 200")

    session = owner_session(api, cfg.admin_email, read_secret(cfg.admin_password_file))
    expect(*api.call("PUT", "/v1/admin/settings", {"invite_only": True}, token=session),
           "invite-only")
    expect(*api.call("POST", "/v1/credentials",
                     {"vault": VAULT, "credentials": {k: creds[k] for k in keys}},
                     token=session), "credentials")
    expect(*api.call("PUT", f"/v1/vaults/{VAULT}/services",
                     {"services": services_payload(declared)}, token=session),
           "services")

    out = Path(cfg.out_dir)
    token_path = out / "agent-token"
    existing = token_path.read_text().strip() if token_path.exists() else ""
    token, action = agent_token(api, session, cfg.agent, existing)
    if token != existing:
        write_owned(token_path, token + "\n", 0o400)

    status, ca = api.call("GET", "/v1/mitm/ca.pem", raw=True)
    expect(status, ca[:200], "CA fetch")
    bundle = Path(cfg.system_ca_bundle).read_text().rstrip("\n") + "\n" + ca
    bundle_path = out / "ca-bundle.pem"
    write_owned(bundle_path, bundle, 0o444)
    write_owned(out / "proxy.env", proxy_env(cfg, token, bundle_path, keys), 0o400)

    log(f"{len(keys)} credentials, {len(declared)} services, agent token {action}")
    if token != existing and cfg.on_token_change:
        result = run_cmd(shlex.split(cfg.on_token_change), check=False)
        if result.returncode != 0:
            log(f"on-token-change exited {result.returncode}")
    return 0


def main(argv=None, env=None):
    del argv
    cfg = Config.from_env(env)
    try:
        return run(cfg, Api(cfg.addr))
    except (RuntimeError, OSError, ValueError) as e:
        log(f"FATAL: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
