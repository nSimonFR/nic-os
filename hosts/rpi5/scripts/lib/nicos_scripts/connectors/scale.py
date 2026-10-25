#!/usr/bin/env python3
"""
scale-to-ryot: webhook -> Ryot V2 fitness-plugin shim for the Loftilla/QN body scale.

ble-scale-sync (the BLE bridge) decodes the scale and POSTs a body-composition
JSON to this shim's /measurement endpoint. We translate that into one
measurement entry via the `ryot/fitness` plugin's `measurement-reading-log`
operation: one reading per statistic, each on the user's `measurement-metric`
whose `key` matches (created with `measurement-metric-create` if missing).

Idempotency: the invoke carries an idempotency key derived from the timestamp
and values, so retrying the same push returns the first result instead of a
second entry. V2 does NOT dedupe on timestamp the way V1 upserted: a payload
re-delivered by ble-scale-sync gets a fresh timestamp and becomes a new entry.

Stdlib only (no third-party deps). All config comes from the environment:

  SHIM_PORT     listen port on 127.0.0.1            (default 8347)
  SHIM_KEY      shared secret; must match the X-Shim-Key header ble-scale-sync
                sends (set in its config.yaml). Required.
  RYOT_URL      Ryot V2 base URL, without /api      (default http://127.0.0.1:13350)
  RYOT_API_KEY  Ryot V2 user API key (X-Api-Key)    Required. RYOT_TOKEN is read
                as a fallback name; it must hold a V2 key, not a V1 token.
  MEASUREMENT_NAME  optional comment stored on each entry (default "Loftilla")

ble-scale-sync's webhook payload is the BodyComposition object (all numbers):
  weight, impedance, bmi, bodyFatPercent, waterPercent, boneMass, muscleMass,
  visceralFat, physiqueRating, bmr, metabolicAge
(+ user_name / user_slug when multi-user context is present — ignored here since
there is a single Ryot account).
"""

import hashlib
import json
import sys
import threading
import urllib.error
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .. import ryot
from ..logs import logger
from ..secrets import env_int, env_str

log = logger("scale-to-ryot")

FITNESS = "ryot/fitness"

# ble-scale-sync BodyComposition field -> Ryot measurement metric key. These are
# the keys the V1 -> V2 migration gave the user's existing metrics.
FIELD_MAP = {
    "weight": "weight",
    "bmi": "bmi",
    "bodyFatPercent": "body_fat",
    "waterPercent": "body_water",
    "muscleMass": "muscle_mass",
    "boneMass": "bone_mass",
    "visceralFat": "visceral_fat",
    "physiqueRating": "physique_rating",
    "bmr": "basal_metabolic_rate",
    "metabolicAge": "metabolic_age",
    "impedance": "impedance",
}


def _col(field):
    return {"type": "column", "tableAlias": "metric", "field": field}


# The caller's measurement metrics (RyotQL scopes entity rows to the key's user).
METRICS_QUERY = {
    "metrics": {
        "from": {"table": "entity", "alias": "metric"},
        "where": {
            "type": "and",
            "predicates": [
                {
                    "type": "comparison",
                    "operator": "eq",
                    "left": _col("entitySchemaSlug"),
                    "right": {"type": "literal", "value": "measurement-metric"},
                },
                {
                    "type": "comparison",
                    "operator": "eq",
                    "left": _col("entitySchemaPluginId"),
                    "right": {
                        "type": "pluginId",
                        "reference": {"kind": "package", "packageId": FITNESS, "scope": "system"},
                    },
                },
            ],
        },
        "output": {
            "type": "rows",
            "pagination": {"limit": 100},
            "orderBy": [{"direction": "asc", "expr": _col("id")}],
            "fields": [
                {"key": "id", "expr": _col("id")},
                {
                    "key": "key",
                    "expr": {"type": "jsonPath", "expr": _col("properties"), "path": ["key"]},
                },
            ],
        },
    }
}

# Two concurrent first-ever pushes would each create the same missing metric.
_push_lock = threading.Lock()


@dataclass(frozen=True)
class Config:
    port: int = 8347
    shim_key: str = ""
    ryot_url: str = "http://127.0.0.1:13350"
    ryot_api_key: str = ""
    measurement_name: str = "Loftilla"

    @classmethod
    def from_env(cls, env=None):
        return cls(
            port=env_int("SHIM_PORT", 8347, env),
            shim_key=env_str("SHIM_KEY", "", env),
            ryot_url=env_str("RYOT_URL", "http://127.0.0.1:13350", env),
            ryot_api_key=env_str("RYOT_API_KEY", "", env) or env_str("RYOT_TOKEN", "", env),
            measurement_name=env_str("MEASUREMENT_NAME", "Loftilla", env),
        )


def build_statistics(data):
    stats = []
    for src, dst in FIELD_MAP.items():
        val = data.get(src)
        if val is None:
            continue
        try:
            num = float(val)
        except (TypeError, ValueError):
            continue
        if num == 0 and src != "weight":
            # QN scales emit 0 for body-comp fields on a weight-only frame
            # (before impedance). Skip zeros so we don't log a bogus reading.
            continue
        # %g drops float noise (82.50 -> 82.5) before it reaches the JSON number.
        stats.append({"name": dst, "value": f"{num:g}"})
    return stats


def metric_name(key):
    """Display name for a created metric; Ryot derives the same key back from it."""
    return key.replace("_", " ").title()


def metric_ids(cfg, keys, opener=None):
    """key -> metric entity id for `keys`, creating any metric the user lacks."""
    data = ryot.ryotql(cfg.ryot_url, cfg.ryot_api_key, METRICS_QUERY, opener=opener)
    found = {row["key"]: row["id"] for row in data["metrics"]["items"] if row.get("key")}
    for key in keys:
        if key not in found:
            created = ryot.invoke_operation(
                cfg.ryot_url,
                cfg.ryot_api_key,
                FITNESS,
                "measurement-metric-create",
                {"name": metric_name(key)},
                opener=opener,
            )
            found[key] = created["entityId"]
            log(f"created Ryot measurement metric {key!r}")
    return {key: found[key] for key in keys}


def submission_id(stats, timestamp):
    digest = hashlib.sha256(json.dumps([timestamp, stats], sort_keys=True).encode())
    return "scale-" + digest.hexdigest()[:40]


def log_input(stats, ids, comment, timestamp):
    sub_id = submission_id(stats, timestamp)
    return {
        "occurredAt": timestamp,
        "comment": comment,
        "values": [{"metricId": ids[s["name"]], "value": float(s["value"])} for s in stats],
        # Must not vary on retry: a reused idempotency key with a different
        # payload is a 400, not a replay.
        "submittedAt": timestamp,
        "submissionId": sub_id,
    }


def push_to_ryot(cfg, stats, timestamp=None, opener=None):
    """Log `stats` as one measurement entry; returns its timestamp.

    Raises RuntimeError on a non-2xx (ryot.api_post) or an "incomplete" save.
    """
    ts = timestamp or datetime.now(timezone.utc).isoformat()
    with _push_lock:
        ids = metric_ids(cfg, [s["name"] for s in stats], opener=opener)
        payload = log_input(stats, ids, cfg.measurement_name, ts)
        result = ryot.invoke_operation(
            cfg.ryot_url,
            cfg.ryot_api_key,
            FITNESS,
            "measurement-reading-log",
            payload,
            idempotency_key=payload["submissionId"],
            opener=opener,
        )
    if not isinstance(result, dict) or result.get("status") != "saved":
        raise RuntimeError(f"Ryot measurement not fully saved: {result}")
    return ts


def make_handler(cfg, push=None, log=log):
    """Build the request handler class bound to this config.

    `push(stats) -> timestamp` is the seam: production uses the real Ryot
    operation, tests pass a recorder (or a raiser, to exercise the 502 path).
    """
    do_push = push or (lambda stats: push_to_ryot(cfg, stats))

    class Handler(BaseHTTPRequestHandler):
        first_payload_logged = False

        def _reply(self, code, msg):
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(msg.encode())

        def do_GET(self):
            # cheap healthcheck (ble-scale-sync sends a HEAD/GET probe at startup)
            if self.path in ("/", "/health", "/measurement"):
                self._reply(200, "ok")
            else:
                self._reply(404, "not found")

        def do_HEAD(self):
            self.send_response(200)
            self.end_headers()

        def do_POST(self):
            if self.path != "/measurement":
                return self._reply(404, "not found")
            if cfg.shim_key and self.headers.get("X-Shim-Key") != cfg.shim_key:
                log("rejected POST: bad or missing X-Shim-Key")
                return self._reply(401, "unauthorized")
            try:
                length = int(self.headers.get("Content-Length", "0"))
                data = json.loads(self.rfile.read(length).decode() or "{}")
            except (ValueError, TypeError) as e:
                log(f"bad JSON body: {e}")
                return self._reply(400, "bad request")

            if not Handler.first_payload_logged:
                # One-time: log the raw payload so we can confirm/adjust FIELD_MAP.
                log(f"first payload received: {json.dumps(data)}")
                Handler.first_payload_logged = True

            stats = build_statistics(data)
            if not stats:
                log(f"no usable statistics in payload: {json.dumps(data)}")
                return self._reply(422, "no statistics")
            try:
                ts = do_push(stats)
                names = ", ".join(s["name"] for s in stats)
                log(f"pushed measurement @ {ts} ({len(stats)} stats: {names})")
                self._reply(200, "ok")
            except (urllib.error.URLError, RuntimeError, KeyError, TypeError, ValueError) as e:
                log(f"failed to push to Ryot: {e}")
                self._reply(502, "ryot push failed")

        def log_message(self, *args):
            pass  # silence default per-request stderr logging

    return Handler


def serve(cfg, server_class=ThreadingHTTPServer):
    log(f"listening on 127.0.0.1:{cfg.port}, forwarding to {cfg.ryot_url}")
    server_class(("127.0.0.1", cfg.port), make_handler(cfg)).serve_forever()


def main(env=None):
    cfg = Config.from_env(env)
    if not cfg.ryot_api_key:
        log("FATAL: RYOT_API_KEY (or RYOT_TOKEN) not set")
        return 1
    if not cfg.shim_key:
        log("WARNING: SHIM_KEY empty — webhook auth disabled")
    serve(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
