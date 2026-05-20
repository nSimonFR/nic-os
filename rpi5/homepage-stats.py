#!/usr/bin/env python3
"""Tiny stats aggregation API for homepage-dashboard widgets.

Aggregates data from multiple service APIs into simple JSON endpoints,
refreshed once per day. Serves on 127.0.0.1:8087.

Endpoints:
  /          — all stats
  /sure      — Sure (accounts, transactions, net worth)
  /openwebui — Open WebUI (models, chats, messages)

Refresh cadence: 86400s (daily). Sure is socket-activated (rpi5/sure.nix)
with a 600s idle timer; the daily poll wakes it briefly (~10 min), then
it sleeps for the next ~23h50m. The stats are written to disk after each
refresh so a service restart preserves the last good values rather than
serving an empty payload until the next nightly refresh.

State file: $STATE_DIRECTORY/stats.json (set by systemd StateDirectory=).
Falls back to /var/lib/homepage-stats/stats.json if not in a unit.
"""

import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time

CURL = os.environ.get("CURL_BIN", "curl")
SQLITE = os.environ.get("SQLITE_BIN", "sqlite3")
ENV_FILE = "/run/homepage-dashboard/env"
OWUI_DB = "/var/lib/private/open-webui/data/webui.db"
STATE_DIR = os.environ.get("STATE_DIRECTORY", "/var/lib/homepage-stats")
STATE_FILE = os.path.join(STATE_DIR, "stats.json")
REFRESH_INTERVAL = 86400  # seconds — see module docstring

stats = {"sure": {}, "openwebui": {}}
stats_lock = threading.Lock()


def fetch_sure():
    try:
        env = open(ENV_FILE).read()
        key = [l.split("=", 1)[1].strip() for l in env.strip().split("\n") if "SURE_KEY" in l][0]
        accts = json.loads(subprocess.check_output([
            CURL, "-sf",
            "http://127.0.0.1:13334/api/v1/accounts",
            "-H", f"X-Api-Key: {key}", "-H", "Accept: application/json"
        ]))
        txns = json.loads(subprocess.check_output([
            CURL, "-sf",
            "http://127.0.0.1:13334/api/v1/transactions?per_page=1",
            "-H", f"X-Api-Key: {key}", "-H", "Accept: application/json"
        ]))
        accounts = accts.get("accounts", [])

        def parse_bal(s):
            num = re.sub(r"[^\d.\-]", "", s.replace(",", ""))
            return float(num) if num else 0

        assets = sum(parse_bal(a["balance"]) for a in accounts if a["classification"] == "asset")
        liabilities = sum(parse_bal(a["balance"]) for a in accounts if a["classification"] == "liability")
        with stats_lock:
            stats["sure"] = {
                "accounts": accts.get("pagination", {}).get("total_count", 0),
                "transactions": txns.get("pagination", {}).get("total_count", 0),
                "net_worth": round(assets - liabilities),
            }
    except Exception as e:
        with stats_lock:
            stats["sure"]["error"] = str(e)


def fetch_openwebui():
    try:
        models = json.loads(subprocess.check_output([
            CURL, "-sf", "http://127.0.0.1:4001/v1/models"
        ]))
        chats = subprocess.check_output([
            SQLITE, OWUI_DB, "SELECT COUNT(*) FROM chat;"
        ]).decode().strip()
        messages = subprocess.check_output([
            SQLITE, OWUI_DB, "SELECT COUNT(*) FROM chat_message;"
        ]).decode().strip()
        with stats_lock:
            stats["openwebui"] = {
                "models": len(models.get("data", [])),
                "chats": int(chats),
                "messages": int(messages),
            }
    except Exception as e:
        with stats_lock:
            stats["openwebui"]["error"] = str(e)


def load_cache():
    try:
        with open(STATE_FILE) as f:
            payload = json.load(f)
        with stats_lock:
            for k in stats:
                stats[k] = payload.get(k, {})
        return payload.get("_fetched_at", 0)
    except FileNotFoundError:
        return 0
    except Exception as e:
        print(f"cache load failed: {e}", file=sys.stderr)
        return 0


def save_cache(ts):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with stats_lock:
            payload = {k: dict(v) for k, v in stats.items()}
            payload["_fetched_at"] = ts
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, STATE_FILE)
    except Exception as e:
        print(f"cache save failed: {e}", file=sys.stderr)


def refresh(initial_fetched_at):
    last_fetched = initial_fetched_at
    while True:
        next_due = last_fetched + REFRESH_INTERVAL
        now = time.time()
        wait = max(0, next_due - now)
        if wait:
            time.sleep(wait)
        try:
            fetch_sure()
            fetch_openwebui()
            last_fetched = time.time()
            save_cache(last_fetched)
        except Exception as e:
            print(f"refresh error: {e}", file=sys.stderr)
            # Retry in 1 hour on failure rather than waiting another full day.
            last_fetched = time.time() - REFRESH_INTERVAL + 3600


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with stats_lock:
            if self.path == "/sure":
                data = dict(stats["sure"])
            elif self.path == "/openwebui":
                data = dict(stats["openwebui"])
            else:
                data = {"sure": dict(stats["sure"]), "openwebui": dict(stats["openwebui"])}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    # Load cache synchronously before serving so a restart never returns
    # an empty payload while waiting on the daily refresh.
    initial_fetched_at = load_cache()
    threading.Thread(target=refresh, args=(initial_fetched_at,), daemon=True).start()
    http.server.HTTPServer(("127.0.0.1", 8087), Handler).serve_forever()
