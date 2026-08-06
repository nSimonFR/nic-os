#!/usr/bin/env python3
"""
scale-to-ryot: webhook -> Ryot GraphQL shim for the Loftilla/QN body scale.

ble-scale-sync (the BLE bridge) decodes the scale and POSTs a body-composition
JSON to this shim's /measurement endpoint. We translate that into a Ryot
`createOrUpdateUserMeasurement` GraphQL mutation and push it to the local Ryot
backend. Ryot upserts on `timestamp`, so re-delivery is idempotent.

Stdlib only (no third-party deps). All config comes from the environment:

  SHIM_PORT     listen port on 127.0.0.1            (default 8347)
  SHIM_KEY      shared secret; must match the X-Shim-Key header ble-scale-sync
                sends (set in its config.yaml). Required.
  RYOT_URL      Ryot GraphQL endpoint               (default http://127.0.0.1:13352/graphql)
  RYOT_TOKEN    Ryot per-user API token (Bearer)    Required.
  MEASUREMENT_NAME  optional label stored on each measurement (default "Loftilla")

ble-scale-sync's webhook payload is the BodyComposition object (all numbers):
  weight, impedance, bmi, bodyFatPercent, waterPercent, boneMass, muscleMass,
  visceralFat, physiqueRating, bmr, metabolicAge
(+ user_name / user_slug when multi-user context is present — ignored here since
there is a single Ryot account).
"""

import json
import sys
import urllib.error
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .. import ryot
from ..logs import logger
from ..secrets import env_int, env_str

log = logger("scale-to-ryot")

# ble-scale-sync BodyComposition field -> Ryot measurement statistic name.
# The Ryot side must have these names in the user's measurement preferences for
# them to render (see the deploy step that extends fitness.measurements).
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

MUTATION = (
    "mutation($i:UserMeasurementInput!){createOrUpdateUserMeasurement(input:$i)}"
)


@dataclass(frozen=True)
class Config:
    port: int = 8347
    shim_key: str = ""
    ryot_url: str = "http://127.0.0.1:13352/graphql"
    ryot_token: str = ""
    measurement_name: str = "Loftilla"

    @classmethod
    def from_env(cls, env=None):
        return cls(
            port=env_int("SHIM_PORT", 8347, env),
            shim_key=env_str("SHIM_KEY", "", env),
            ryot_url=env_str("RYOT_URL", "http://127.0.0.1:13352/graphql", env),
            ryot_token=env_str("RYOT_TOKEN", "", env),
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
            # (before impedance). Skip zeros so we don't overwrite a good value.
            continue
        # Ryot Decimal accepts a string; trim trailing zeros for tidiness.
        stats.append({"name": dst, "value": f"{num:g}"})
    return stats


def measurement_input(stats, name, timestamp):
    return {
        "timestamp": timestamp,
        "name": name,
        "information": {
            "assets": {
                "s3Images": [],
                "s3Videos": [],
                "remoteImages": [],
                "remoteVideos": [],
            },
            "statistics": stats,
        },
    }


def push_to_ryot(cfg, stats, timestamp=None, opener=None):
    ts = timestamp or datetime.now(timezone.utc).isoformat()
    data = ryot.graphql(
        cfg.ryot_url,
        cfg.ryot_token,
        MUTATION,
        {"i": measurement_input(stats, cfg.measurement_name, ts)},
        opener=opener,
    )
    return data["createOrUpdateUserMeasurement"]


def make_handler(cfg, push=None, log=log):
    """Build the request handler class bound to this config.

    `push(stats) -> timestamp` is the seam: production uses the real Ryot
    mutation, tests pass a recorder (or a raiser, to exercise the 502 path).
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
            except (urllib.error.URLError, RuntimeError, KeyError) as e:
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
    if not cfg.ryot_token:
        log("FATAL: RYOT_TOKEN not set")
        return 1
    if not cfg.shim_key:
        log("WARNING: SHIM_KEY empty — webhook auth disabled")
    serve(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
