#!/usr/bin/env python3
"""
aperture-config-sync: push Aperture's config, with the gate's live model list.

Aperture only routes model ids its provider config names, while tiny-llm-gate
discovers upstream models at runtime and Anthropic ships new Claude ids. On a
timer, this merges the gate's /v1/models into `rpi5-gate` and Anthropic's
/v1/models into `rpi5-gate-anthropic` of the Nix-built base config, and PUTs
the result only when it differs from what Aperture holds.

Aperture's PUT takes the current `hash` (optimistic concurrency). If either
list cannot be read, Aperture is left untouched rather than shrunk. Writes
only with APERTURE_APPLY=1.

Before a push, every sleepy connector (`send_caller_identity`) is MCP-initialized
until it answers: Aperture re-lists connectors on a config change, and one whose
backend is still cold comes back with no tools until the next change.

Aperture hides stored secrets, so a rotated one cannot be seen in its config:
APERTURE_SYNC_STATE keeps a SHA-256 of the secrets last pushed, and a change in
it forces a push. It is left empty while a sleepy connector did not answer the
wake, so the next run pushes again. Deleting that file forces the next push.

A connector whose `auth.secret` is `env:NAME` gets that variable's value, named
in APERTURE_CONNECTOR_SECRETS, or else the systemd credential of that name
(raw single-value agenix files); one with neither is left out rather than
pushed with an empty token.

Env: APERTURE_URL, APERTURE_BASE_CONFIG, GATE_MODELS_URL, APERTURE_PROVIDER,
ANTHROPIC_TOKEN_FILE, ANTHROPIC_PROVIDER, STORJ_S3_ACCESS_KEY,
STORJ_S3_ACCESS_SECRET, APERTURE_CONNECTOR_SECRETS (+ the variables it names),
APERTURE_APPLY.
"""

import hashlib
import http.client
import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from ..httpjson import get_json, http_json
from ..logs import logger
from ..secrets import env_str, read_secret

log = logger("aperture-config-sync", lambda: sys.stderr)


@dataclass(frozen=True)
class Config:
    aperture_url: str = ""
    base_config: str = ""
    gate_models_url: str = "http://127.0.0.1:4001/v1/models"
    provider: str = "rpi5-gate"
    anthropic_token_file: str = ""
    anthropic_provider: str = "rpi5-gate-anthropic"
    anthropic_models_url: str = "https://api.anthropic.com/v1/models?limit=1000"
    s3_key: str = ""
    s3_secret: str = ""
    connector_secrets: dict = field(default_factory=dict)
    apply: bool = False
    state_file: str = ""

    @classmethod
    def from_env(cls, env=None):
        return cls(
            aperture_url=env_str("APERTURE_URL", "", env).rstrip("/"),
            base_config=env_str("APERTURE_BASE_CONFIG", "", env),
            gate_models_url=env_str("GATE_MODELS_URL", cls.gate_models_url, env),
            provider=env_str("APERTURE_PROVIDER", cls.provider, env),
            anthropic_token_file=env_str("ANTHROPIC_TOKEN_FILE", "", env),
            anthropic_provider=env_str(
                "ANTHROPIC_PROVIDER", cls.anthropic_provider, env
            ),
            s3_key=env_str("STORJ_S3_ACCESS_KEY", "", env),
            s3_secret=env_str("STORJ_S3_ACCESS_SECRET", "", env),
            connector_secrets={
                name: connector_secret(name, env)
                for name in env_str("APERTURE_CONNECTOR_SECRETS", "", env).split()
            },
            apply=env_str("APERTURE_APPLY", "", env) == "1",
            state_file=env_str("APERTURE_SYNC_STATE", "", env),
        )


def connector_secret(name, env=None):
    """`$name`, else `$CREDENTIALS_DIRECTORY/<name>`, else ""."""
    value = env_str(name, "", env)
    creds = env_str("CREDENTIALS_DIRECTORY", "", env)
    if not value and creds and (path := Path(creds) / name).is_file():
        value = read_secret(path)
    return value


def gate_ids(body):
    """Model ids from the gate's /v1/models, minus `vendor/name` slugs.

    A slug names the same model as its bare id, and Aperture matches ids by
    suffix, so listing both only adds ambiguity.
    """
    return {m["id"] for m in body.get("data", []) if m.get("id") and "/" not in m["id"]}


def claude_ids(cfg, opener=None):
    """Anthropic's model ids, read with the Claude Code OAuth token. Empty set
    when no token file is configured."""
    if not cfg.anthropic_token_file:
        return set()
    token = read_secret(cfg.anthropic_token_file)
    body = get_json(
        cfg.anthropic_models_url,
        headers={"Authorization": f"Bearer {token}", "anthropic-version": "2023-06-01"},
        timeout=15,
        opener=opener,
    )
    return {m["id"] for m in body.get("data", []) if m.get("id")}


def desired(base, ids, cfg, claude=frozenset()):
    config = json.loads(json.dumps(base))
    for name, extra in ((cfg.provider, ids), (cfg.anthropic_provider, claude)):
        prov = config["providers"].get(name)
        if prov is not None and extra:
            prov["models"] = sorted(set(prov.get("models", [])) | set(extra))
    s3 = config.get("exporters", {}).get("s3")
    if s3 is not None:
        s3["access_key_id"] = cfg.s3_key
        s3["access_secret"] = cfg.s3_secret
    servers = config.get("connectors", {}).get("servers", {})
    for cid in missing_secrets(base, cfg):
        servers.pop(cid)
    for server in servers.values():
        auth = server.get("auth") or {}
        ref = auth.get("secret", "")
        if ref.startswith("env:"):
            auth["secret"] = cfg.connector_secrets[ref[4:]]
    return config


def missing_secrets(base, cfg):
    """Connector ids whose `env:` secret has no value."""
    servers = base.get("connectors", {}).get("servers", {})
    return sorted(
        cid
        for cid, server in servers.items()
        if (ref := (server.get("auth") or {}).get("secret", "")).startswith("env:")
        and not cfg.connector_secrets.get(ref[4:])
    )


def comparable(config):
    """Drop what Aperture rewrites on store: provider apikeys, connector tokens
    and the S3 secret become `keyid:…` references, and a connector gains
    `provider: "Custom"`. Model order carries no meaning either. So a rotated
    secret alone does not trigger a push."""
    if not isinstance(config, dict):
        return config
    out = json.loads(json.dumps(config))
    for prov in out.get("providers", {}).values():
        prov.pop("apikey", None)
        prov["models"] = sorted(prov.get("models", []))
    out.get("exporters", {}).get("s3", {}).pop("access_secret", None)
    for server in out.get("connectors", {}).get("servers", {}).values():
        (server.get("auth") or {}).pop("secret", None)
        if server.get("provider") == "Custom":
            server.pop("provider")
    return out


def secrets_digest(config):
    """SHA-256 over every secret `comparable` drops, so it never leaves this host."""
    found = [
        (f"provider:{k}", p.get("apikey", ""))
        for k, p in config.get("providers", {}).items()
    ]
    found.append(
        ("s3", config.get("exporters", {}).get("s3", {}).get("access_secret", ""))
    )
    found += [
        (f"connector:{k}", (s.get("auth") or {}).get("secret", ""))
        for k, s in config.get("connectors", {}).get("servers", {}).items()
    ]
    return hashlib.sha256(json.dumps(sorted(found)).encode()).hexdigest()


def pushed_digest(cfg):
    try:
        return Path(cfg.state_file).read_text().strip() if cfg.state_file else ""
    except OSError:
        return ""


def record_digest(cfg, digest):
    if not cfg.state_file:
        return
    tmp = Path(f"{cfg.state_file}.tmp")
    tmp.write_text(digest + "\n")
    os.replace(tmp, cfg.state_file)


def current(cfg, opener=None):
    """(config dict or None, hash). None when Aperture's text isn't plain JSON."""
    body = get_json(f"{cfg.aperture_url}/api/config", timeout=15, opener=opener)
    try:
        parsed = json.loads(body.get("config") or "null")
    except ValueError:
        parsed = None
    return parsed, body.get("hash", "")


def put(cfg, config, digest, opener=None):
    payload = json.dumps({"config": json.dumps(config), "hash": digest}).encode()
    req = urllib.request.Request(
        f"{cfg.aperture_url}/api/config",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="PUT",
    )
    return http_json(req, timeout=30, opener=opener)


INITIALIZE = json.dumps(
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "aperture-config-sync", "version": "1"},
        },
    }
).encode()


def auth_headers(server):
    """The headers Aperture itself sends this connector."""
    auth = server.get("auth") or {}
    if auth.get("type") == "bearer_token":
        return {"Authorization": f"Bearer {auth['secret']}"}
    if auth.get("type") == "api_key" and auth.get("in") == "header":
        return {auth["name"]: auth["secret"]}
    return {}


def sse_events(text):
    """The data of each SSE event, its `data:` lines joined."""
    events, data = [], []
    for line in text.splitlines() + [""]:
        if line.startswith("data:"):
            data.append(line[5:].removeprefix(" "))
        elif not line and data:
            events.append("\n".join(data))
            data = []
    return events


def initialized(body):
    """The answer (plain JSON or SSE) holds the JSON-RPC response to INITIALIZE."""
    text = body.decode(errors="replace")
    for chunk in [text, *sse_events(text)]:
        try:
            msg = json.loads(chunk)
        except ValueError:
            continue
        if (
            isinstance(msg, dict)
            and msg.get("jsonrpc") == "2.0"
            and msg.get("id") == 1
            and isinstance(msg.get("result"), dict)
            and "protocolVersion" in msg["result"]
        ):
            return True
    return False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # urllib then raises the 3xx as an HTTPError


# The wake carries each connector's credential: never to another URL.
_open_no_redirect = urllib.request.build_opener(_NoRedirect).open


def wake(config, opener=None, sleep=time.sleep, deadline=90, clock=time.monotonic):
    """MCP-initialize each sleepy connector until it answers: its socket proxy
    wakes the backend, and the backend has started its MCP server (a stdio
    bridge spawns its child on initialize). Returns the URLs still not ready
    once `deadline` seconds have passed, by the clock or in sleeps."""
    opener = opener or _open_no_redirect
    servers = config.get("connectors", {}).get("servers", {})
    sleepy = [s for s in servers.values() if s.get("send_caller_identity")]
    end = clock() + deadline

    def ready(server):
        req = urllib.request.Request(
            server["url"],
            data=INITIALIZE,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                **auth_headers(server),
            },
            method="POST",
        )
        slept = 0
        while True:
            left = min(end - clock(), deadline - slept)
            if left <= 0:
                return server["url"]
            try:
                with opener(req, timeout=max(1, left)) as r:
                    if initialized(r.read()):
                        return None
            except (OSError, http.client.HTTPException):  # IncompleteRead included
                pass
            pause = min(10, end - clock(), deadline - slept)
            if pause <= 0:
                return server["url"]
            sleep(pause)
            slept += pause

    # All at once: the deadline then bounds the whole wake, not one batch.
    with ThreadPoolExecutor(max_workers=max(1, len(sleepy))) as pool:
        return [u for u in pool.map(ready, sleepy) if u]


def run(cfg, opener=None, sleep=time.sleep, attempts=5):
    base = json.loads(Path(cfg.base_config).read_text())
    try:
        ids = gate_ids(get_json(cfg.gate_models_url, timeout=15, opener=opener))
        claude = claude_ids(cfg, opener=opener)
    except (OSError, ValueError) as e:
        log(f"model list unreadable ({e}); Aperture left as is")
        return 0
    want = desired(base, ids, cfg, claude)
    for cid in missing_secrets(base, cfg):
        log(f"connector {cid}: secret unset, left out")
    count = len(want["providers"][cfg.provider]["models"])
    secrets = secrets_digest(want)
    # A new secret, or a connector left unready by the last push (no digest).
    stale = bool(cfg.state_file) and pushed_digest(cfg) != secrets

    woken = False
    for attempt in range(1, attempts + 1):
        try:
            have, digest = current(cfg, opener=opener)
            if comparable(have) == comparable(want) and not stale:
                log(f"unchanged ({count} gate models)")
                return 0
            if not cfg.apply:
                log(f"would push {count} gate models (dry run)")
                return 0
            if not woken:
                unready = wake(want, opener=opener, sleep=sleep)
                for url in unready:
                    log(f"{url} not ready; pushing again next run")
                woken = True
                if unready and cfg.state_file:
                    # Before the PUT: a lost answer or a later write error must
                    # still leave the next run pushing again.
                    try:
                        record_digest(cfg, "")
                    except OSError as e:
                        log(f"{cfg.state_file} unwritable ({e}); not pushing")
                        return 1
            result = put(cfg, want, digest, opener=opener)
            if result.get("success"):
                why = " (secrets changed or a connector was unready)" if stale else ""
                log(
                    f"pushed {count} gate models{why} (hash {digest} -> {result.get('hash')})"
                )
                if not unready:
                    try:
                        record_digest(cfg, secrets)
                    except OSError as e:
                        log(
                            f"pushed, but {cfg.state_file} unwritable ({e}): next run pushes again"
                        )
                return 0
            err = (result.get("error") or {}).get("message") or result.get("message")
        except (OSError, ValueError) as e:
            err = str(e)
        log(f"attempt {attempt}/{attempts} failed: {err}")
        if attempt < attempts:
            sleep(5)
    return 1


def main(argv=None, env=None):
    del argv
    cfg = Config.from_env(env)
    if not cfg.aperture_url or not cfg.base_config:
        log("APERTURE_URL and APERTURE_BASE_CONFIG are required")
        return 1
    return run(cfg)


if __name__ == "__main__":
    sys.exit(main())
