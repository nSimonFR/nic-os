#!/usr/bin/env python3
"""
scale-to-ryot: webhook -> Ryot GraphQL shim for the Loftilla/QN body scale.

ble-scale-sync (the BLE bridge) decodes the scale and POSTs a body-composition
JSON to this shim's /measurement endpoint. We translate that into a Ryot
`createOrUpdateUserMeasurement` GraphQL mutation and push it to the local Ryot
backend. Ryot upserts on `timestamp`, so re-delivery is idempotent.

Stdlib only (no third-party deps) — mirrors the homepage-stats / travel-cal-sync
in-repo Python-service pattern. All config comes from the environment:

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
import os
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SHIM_PORT = int(os.environ.get("SHIM_PORT", "8347"))
SHIM_KEY = os.environ.get("SHIM_KEY", "")
RYOT_URL = os.environ.get("RYOT_URL", "http://127.0.0.1:13352/graphql")
RYOT_TOKEN = os.environ.get("RYOT_TOKEN", "")
MEASUREMENT_NAME = os.environ.get("MEASUREMENT_NAME", "Loftilla")

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

_first_payload_logged = False


def log(msg):
    print(f"[scale-to-ryot] {msg}", flush=True)


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


def push_to_ryot(stats):
    ts = datetime.now(timezone.utc).isoformat()
    variables = {
        "i": {
            "timestamp": ts,
            "name": MEASUREMENT_NAME,
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
    }
    body = json.dumps({"query": MUTATION, "variables": variables}).encode()
    req = urllib.request.Request(
        RYOT_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + RYOT_TOKEN,
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        out = json.loads(resp.read().decode())
    if out.get("errors"):
        raise RuntimeError(f"Ryot GraphQL error: {out['errors']}")
    return out["data"]["createOrUpdateUserMeasurement"]


class Handler(BaseHTTPRequestHandler):
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
        global _first_payload_logged
        if self.path != "/measurement":
            return self._reply(404, "not found")
        if SHIM_KEY and self.headers.get("X-Shim-Key") != SHIM_KEY:
            log("rejected POST: bad or missing X-Shim-Key")
            return self._reply(401, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            data = json.loads(self.rfile.read(length).decode() or "{}")
        except (ValueError, TypeError) as e:
            log(f"bad JSON body: {e}")
            return self._reply(400, "bad request")

        if not _first_payload_logged:
            # One-time: log the raw payload so we can confirm/adjust FIELD_MAP.
            log(f"first payload received: {json.dumps(data)}")
            _first_payload_logged = True

        stats = build_statistics(data)
        if not stats:
            log(f"no usable statistics in payload: {json.dumps(data)}")
            return self._reply(422, "no statistics")
        try:
            ts = push_to_ryot(stats)
            names = ", ".join(s["name"] for s in stats)
            log(f"pushed measurement @ {ts} ({len(stats)} stats: {names})")
            self._reply(200, "ok")
        except (urllib.error.URLError, RuntimeError, KeyError) as e:
            log(f"failed to push to Ryot: {e}")
            self._reply(502, "ryot push failed")

    def log_message(self, *args):
        pass  # silence default per-request stderr logging


def main():
    if not RYOT_TOKEN:
        log("FATAL: RYOT_TOKEN not set")
        sys.exit(1)
    if not SHIM_KEY:
        log("WARNING: SHIM_KEY empty — webhook auth disabled")
    log(f"listening on 127.0.0.1:{SHIM_PORT}, forwarding to {RYOT_URL}")
    ThreadingHTTPServer(("127.0.0.1", SHIM_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
