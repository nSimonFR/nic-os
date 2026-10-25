#!/usr/bin/env python3
"""
agent-vault-bootstrap: push the repo's declared state into Agent Vault, whose only
config is its own DB — owner account, credentials (CREDS_FILE + CRED_FILES), services,
and the agent token. Then write OUT_DIR/{agent-token,ca-bundle.pem,proxy.env,gitconfig}.
Idempotent; a lost DB is a re-run. Env: see hosts/rpi5/agent-vault.nix.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from ..logs import logger
from ..secrets import env_str, read_secret

log = logger("agent-vault-bootstrap")

VAULT = "default"  # the owner gets admin on it at registration
CA_VARS = ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
           "NODE_EXTRA_CA_CERTS", "GIT_SSL_CAINFO", "DENO_CERT")


@dataclass(frozen=True)
class Config:
    addr: str = "http://127.0.0.1:14321"
    proxy: str = "127.0.0.1:14322"
    admin_email: str = ""
    admin_password_file: str = ""
    creds_file: str = ""
    cred_files: str = ""
    services_file: str = ""
    out_dir: str = ""
    no_proxy: str = ""
    system_ca_bundle: str = "/etc/ssl/certs/ca-certificates.crt"
    dry_run: bool = True

    @classmethod
    def from_env(cls, env=None):
        def get(name, default=""):
            return env_str(name, default, env)

        return cls(
            addr=get("AGENT_VAULT_ADDR", cls.addr),
            proxy=get("AGENT_VAULT_PROXY", cls.proxy),
            admin_email=get("AGENT_VAULT_ADMIN_EMAIL"),
            admin_password_file=get("AGENT_VAULT_ADMIN_PASSWORD_FILE"),
            creds_file=get("AGENT_VAULT_CREDS_FILE"),
            cred_files=get("AGENT_VAULT_CRED_FILES"),
            services_file=get("AGENT_VAULT_SERVICES_FILE"),
            out_dir=get("AGENT_VAULT_OUT_DIR"),
            no_proxy=get("AGENT_VAULT_NO_PROXY"),
            system_ca_bundle=get("SYSTEM_CA_BUNDLE", cls.system_ca_bundle),
            dry_run=get("AGENT_VAULT_BOOTSTRAP_APPLY") != "1",
        )


def placeholder(key):
    return f"__{key.lower()}__"


def parse_env_file(text):
    """As `. file` reads it: KEY="value" lines too."""
    out = {}
    for line in text.splitlines():
        if "=" not in line or line.lstrip().startswith("#"):
            continue
        k, v = line.split("=", 1)
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        out[k] = v
    return out


def auth_keys(auth):
    """Credential keys an attaching service reads (Agent Vault's Auth.CredentialKeys)."""
    return [auth[f] for f in ("token", "username", "password", "key") if auth.get(f)]


def load_creds(cfg):
    """CREDS_FILE (KEY=VAL), plus `KEY=path` pairs whose file holds just the value.

    `KEY=-path` is optional: a missing file keeps CREDS_FILE's value, if any.
    """
    creds = parse_env_file(Path(cfg.creds_file).read_text())
    for pair in filter(None, cfg.cred_files.split(",")):
        key, path = pair.split("=", 1)
        optional = path.startswith("-")
        path = path.removeprefix("-")
        if optional and not Path(path).exists():
            continue
        creds[key] = read_secret(path)
    return creds


def call(cfg, method, path, body=None, token=None, headers=None, opener=None):
    """(status, text). Errors are statuses, not exceptions."""
    hdrs = {"Content-Type": "application/json", **(headers or {})}
    if token:
        hdrs["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(cfg.addr + path, data=data, headers=hdrs, method=method)
    try:
        with (opener or urllib.request.urlopen)(req, timeout=30) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def ok(result, what):
    status, text = result
    if status not in (200, 201, 204):
        raise RuntimeError(f"{what}: {status} {text[:200]}")
    return json.loads(text) if text.startswith("{") else text


def write_owned(path, text, mode):
    """Atomic write, owned like the directory (we run as root, Hermes reads)."""
    st = os.stat(path.parent)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def run(cfg, opener=None, sleep=time.sleep):
    declared = json.loads(Path(cfg.services_file).read_text())
    keys = sorted({k for s in declared for k in s.get("keys", [])})
    attached = sorted({k for s in declared if "auth" in s for k in auth_keys(s["auth"])})
    creds = load_creds(cfg)
    missing = [k for k in keys + attached if not creds.get(k)]
    if missing:
        raise RuntimeError(f"not in {cfg.creds_file}: {', '.join(missing)}")
    if cfg.dry_run:
        log(f"dry run — would broker {', '.join(keys + attached)}")
        return

    def api(*a, **kw):
        return call(cfg, *a, opener=opener, **kw)

    for _ in range(60):  # the server unit is Type=simple
        try:
            if api("GET", "/health")[0] == 200:
                break
        except OSError:
            pass
        sleep(1)

    login = {"email": cfg.admin_email, "password": read_secret(cfg.admin_password_file)}
    status, text = api("POST", "/v1/auth/login", login)
    if status != 200:  # fresh DB: the first registration becomes the owner
        status, text = api("POST", "/v1/auth/register", login)
    session = json.loads(text).get("token") if text.startswith("{") else None
    if not session:
        raise RuntimeError(f"owner login/register: {status} {text[:200]}")

    ok(api("PUT", "/v1/admin/settings", {"invite_only": True}, token=session), "settings")
    ok(api("POST", "/v1/credentials",
           {"vault": VAULT, "credentials": {k: creds[k] for k in keys + attached}}, token=session),
       "credentials")
    services = [
        {"name": s["name"], "host": s["host"], "auth": s["auth"]} if "auth" in s else
        {"name": s["name"], "host": s["host"], "auth": {"type": "passthrough"},
         "substitutions": [{"key": k, "placeholder": placeholder(k), "in": s["in"]}
                           for k in s["keys"]]}
        for s in declared
    ]
    ok(api("PUT", f"/v1/vaults/{VAULT}/services", {"services": services}, token=session),
       "services")

    out = Path(cfg.out_dir)
    token_file = out / "agent-token"
    token = token_file.read_text().strip() if token_file.exists() else ""
    if not token or api("GET", "/discover", token=token, headers={"X-Vault": VAULT})[0] != 200:
        status, text = api("POST", "/v1/agents", token=session, body={
            "name": "hermes", "vaults": [{"vault_name": VAULT, "vault_role": "proxy"}]})
        if status == 409:
            status, text = api("POST", "/v1/agents/hermes/rotate", {}, token=session)
        token = ok((status, text), "agent token")["av_agent_token"]
        write_owned(token_file, token + "\n", 0o400)
        log("agent token minted")

    bundle = out / "ca-bundle.pem"
    ca = ok(api("GET", "/v1/mitm/ca.pem"), "CA")
    write_owned(bundle, Path(cfg.system_ca_bundle).read_text().rstrip("\n") + "\n" + ca, 0o444)

    proxy_url = f"http://{token}:{VAULT}@{cfg.proxy}"
    no_proxy = ",".join(["localhost", "127.0.0.1", "::1", *filter(None, cfg.no_proxy.split(","))])
    lines = [f"{v}={proxy_url}" for v in ("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy")]
    lines += [f"NO_PROXY={no_proxy}", f"no_proxy={no_proxy}", "NODE_USE_ENV_PROXY=1"]
    lines += [f"{v}={bundle}" for v in CA_VARS]
    lines += [f"{k}={placeholder(k)}" for k in keys]
    env_file = out / "proxy.env"
    text = "\n".join(lines) + "\n"
    # Only rewrite on change: agent-vault-hermes-restart.path watches this file.
    if not env_file.exists() or env_file.read_text() != text:
        write_owned(env_file, text, 0o400)
    # Included by ~/.config/git: every git routes the attaching hosts here,
    # whether or not it runs with proxy.env.
    git = "".join(f'[http "https://{s["host"]}/"]\n\tproxy = {proxy_url}\n\tsslCAInfo = {bundle}\n'
                  for s in declared if "auth" in s)
    write_owned(out / "gitconfig", git, 0o400)
    log(f"{len(keys + attached)} credentials, {len(declared)} services applied")


def main(argv=None, env=None):
    del argv
    try:
        run(Config.from_env(env))
        return 0
    except (RuntimeError, OSError, ValueError, KeyError) as e:
        log(f"FATAL: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
