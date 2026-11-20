#!/usr/bin/env python3
"""Print, per cookie host, the JS that recreates a browser session's cookies.

usage: cookie-js.py <domain-substring> [--source zen|t3] [--store <path>]
Copies each store (WAL included), reads it, deletes the copy, and uses the one
store that holds cookies for the domain.
"""

import base64
import glob
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import urllib.parse

HOME = os.path.expanduser("~")
SOURCES = {
    "zen": (
        f"{HOME}/Library/Application Support/zen/Profiles/*/cookies.sqlite",
        "select host, name, value, path from moz_cookies where host like ?",
    ),
    "t3": (
        f"{HOME}/Library/Application Support/t3code-v2/Partitions/t3code-preview-*/Cookies",
        "select host_key, name, value, path from cookies where host_key like ?",
    ),
}


def arg(flag, default=None):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


def read_store(path, query, domain):
    # Zen holds an exclusive lock on its live store, so SQLite cannot open it even
    # read-only: copy the files instead, WAL included (recent logins sit there).
    tmp = tempfile.mkdtemp()
    try:
        for suffix in ("", "-wal"):
            if os.path.exists(path + suffix):
                shutil.copy(path + suffix, os.path.join(tmp, "c" + suffix))
        db = sqlite3.connect(os.path.join(tmp, "c"))
        try:
            return db.execute(query, (f"%{domain}%",)).fetchall()
        finally:
            db.close()
    finally:
        shutil.rmtree(tmp)


def rails_exp(value):
    try:
        payload = urllib.parse.unquote(value).split("--")[0]
        return json.loads(base64.b64decode(payload + "=="))["_rails"]["exp"]
    except Exception:
        return None


def main():
    domain = sys.argv[1]
    pattern, query = SOURCES[arg("--source", "zen")]
    stores = [arg("--store")] if "--store" in sys.argv else glob.glob(pattern)
    found = {s: rows for s in stores if (rows := read_store(s, query, domain))}
    if not found:
        sys.exit(f"no cookie for {domain} in {len(stores)} store(s): log in first")
    if len(found) > 1:
        listing = "\n".join(f"  {s}" for s in found)
        sys.exit(f"{domain} is in several stores, pick one with --store:\n{listing}")
    by_host = {}
    for host, name, value, path in next(iter(found.values())):
        exp = rails_exp(value)
        if exp:
            print(f"# {name}: token exp {exp}", file=sys.stderr)
        attrs = f"domain={host}; " if host.startswith(".") else ""
        js = f"{name}={value}; {attrs}path={path or '/'}; secure; samesite=lax; max-age=86400"
        by_host.setdefault(host, []).append(f"document.cookie={json.dumps(js)};")
    for host, lines in by_host.items():
        print(f"== any page under {host}" if host.startswith(".") else f"== {host}")
        print("".join(lines) + "1")


main()
