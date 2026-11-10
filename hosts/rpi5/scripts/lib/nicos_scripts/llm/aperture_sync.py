#!/usr/bin/env python3
"""
aperture-config-sync: push Aperture's config, with the gate's live model list.

Aperture only routes model ids its provider config names, while tiny-llm-gate
discovers upstream models at runtime. On a timer, this merges the gate's
/v1/models into the `rpi5-gate` provider of the Nix-built base config and
PUTs the result, only when it differs from what Aperture holds.

Aperture's PUT takes the current `hash` (optimistic concurrency). A gate that
does not answer leaves Aperture untouched. Writes only with APERTURE_APPLY=1.

Env: APERTURE_URL, APERTURE_BASE_CONFIG, GATE_MODELS_URL, APERTURE_PROVIDER,
STORJ_S3_ACCESS_KEY, STORJ_S3_ACCESS_SECRET, APERTURE_APPLY.
"""

import json
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from ..httpjson import get_json, http_json
from ..logs import logger
from ..secrets import env_str

log = logger("aperture-config-sync", lambda: sys.stderr)


@dataclass(frozen=True)
class Config:
    aperture_url: str = ""
    base_config: str = ""
    gate_models_url: str = "http://127.0.0.1:4001/v1/models"
    provider: str = "rpi5-gate"
    s3_key: str = ""
    s3_secret: str = ""
    apply: bool = False

    @classmethod
    def from_env(cls, env=None):
        return cls(
            aperture_url=env_str("APERTURE_URL", "", env).rstrip("/"),
            base_config=env_str("APERTURE_BASE_CONFIG", "", env),
            gate_models_url=env_str("GATE_MODELS_URL", cls.gate_models_url, env),
            provider=env_str("APERTURE_PROVIDER", cls.provider, env),
            s3_key=env_str("STORJ_S3_ACCESS_KEY", "", env),
            s3_secret=env_str("STORJ_S3_ACCESS_SECRET", "", env),
            apply=env_str("APERTURE_APPLY", "", env) == "1",
        )


def gate_ids(body):
    """Model ids from the gate's /v1/models, minus `vendor/name` slugs.

    A slug names the same model as its bare id, and Aperture matches ids by
    suffix, so listing both only adds ambiguity.
    """
    return {m["id"] for m in body.get("data", []) if m.get("id") and "/" not in m["id"]}


def desired(base, ids, cfg):
    config = json.loads(json.dumps(base))
    prov = config["providers"][cfg.provider]
    prov["models"] = sorted(set(prov.get("models", [])) | ids)
    s3 = config.get("exporters", {}).get("s3")
    if s3 is not None:
        s3["access_key_id"] = cfg.s3_key
        s3["access_secret"] = cfg.s3_secret
    return config


def comparable(config):
    """Drop what Aperture rewrites on store: provider apikeys and the S3 secret
    become `keyid:…` references. Model order carries no meaning either. So a
    rotated S3 secret alone does not trigger a push."""
    if not isinstance(config, dict):
        return config
    out = json.loads(json.dumps(config))
    for prov in out.get("providers", {}).values():
        prov.pop("apikey", None)
        prov["models"] = sorted(prov.get("models", []))
    out.get("exporters", {}).get("s3", {}).pop("access_secret", None)
    return out


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


def run(cfg, opener=None, sleep=time.sleep, attempts=5):
    base = json.loads(Path(cfg.base_config).read_text())
    try:
        ids = gate_ids(get_json(cfg.gate_models_url, timeout=15, opener=opener))
    except (OSError, ValueError) as e:
        log(f"gate unreachable ({e}); Aperture left as is")
        return 0
    want = desired(base, ids, cfg)
    count = len(want["providers"][cfg.provider]["models"])

    for attempt in range(1, attempts + 1):
        try:
            have, digest = current(cfg, opener=opener)
            if comparable(have) == comparable(want):
                log(f"unchanged ({count} gate models)")
                return 0
            if not cfg.apply:
                log(f"would push {count} gate models (dry run)")
                return 0
            result = put(cfg, want, digest, opener=opener)
            if result.get("success"):
                log(
                    f"pushed {count} gate models (hash {digest} -> {result.get('hash')})"
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
