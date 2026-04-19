#!/usr/bin/env python3
"""Tiny stats aggregation API for homepage-dashboard widgets.

Aggregates data from multiple service APIs into simple JSON endpoints,
refreshed every 5 minutes. Serves on 127.0.0.1:8087.

Endpoints:
  /          — all stats
  /sure      — Sure (accounts, transactions, net worth)
  /openwebui — Open WebUI (models, chats, messages)
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
REFRESH_INTERVAL = 300  # seconds

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


def refresh():
    while True:
        try:
            fetch_sure()
            fetch_openwebui()
        except Exception as e:
            print(f"refresh error: {e}", file=sys.stderr)
        time.sleep(REFRESH_INTERVAL)


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
    threading.Thread(target=refresh, daemon=True).start()
    time.sleep(2)  # initial fetch
    http.server.HTTPServer(("127.0.0.1", 8087), Handler).serve_forever()
