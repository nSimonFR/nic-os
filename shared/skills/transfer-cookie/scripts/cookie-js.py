#!/usr/bin/env python3
"""Print, per cookie host, the JS that recreates a browser session's cookies.

usage: cookie-js.py <domain-substring> [--source zen|t3]
Reads a copy of the store (WAL included: the live DB is locked and recent
logins sit in the -wal file), then deletes the copy.
"""
import base64, glob, json, os, shutil, sqlite3, sys, tempfile, urllib.parse

HOME = os.path.expanduser("~")
SOURCES = {
    "zen": (f"{HOME}/Library/Application Support/zen/Profiles/*/cookies.sqlite",
            "select host, name, value from moz_cookies where host like ?"),
    "t3": (f"{HOME}/Library/Application Support/t3code-v2/Partitions/t3code-preview-*/Cookies",
           "select host_key, name, value from cookies where host_key like ?"),
}

def rails_exp(value):
    try:
        payload = urllib.parse.unquote(value).split("--")[0]
        return json.loads(base64.b64decode(payload + "=="))["_rails"]["exp"]
    except Exception:
        return None

def main():
    domain = sys.argv[1]
    source = sys.argv[sys.argv.index("--source") + 1] if "--source" in sys.argv else "zen"
    pattern, query = SOURCES[source]
    stores = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    if not stores:
        sys.exit(f"no {source} cookie store")
    tmp = tempfile.mkdtemp()
    try:
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(stores[0] + suffix):
                shutil.copy(stores[0] + suffix, os.path.join(tmp, "c" + suffix))
        rows = sqlite3.connect(os.path.join(tmp, "c")).execute(query, (f"%{domain}%",)).fetchall()
    finally:
        shutil.rmtree(tmp)
    if not rows:
        sys.exit(f"no cookie for {domain} in {stores[0]}: log in there first")
    by_host = {}
    for host, name, value in rows:
        exp = rails_exp(value)
        if exp:
            print(f"# {name}: token exp {exp}", file=sys.stderr)
        attrs = f"domain={host}; " if host.startswith(".") else ""
        js = f"{name}={value}; {attrs}path=/; secure; samesite=lax; max-age=86400"
        by_host.setdefault(host, []).append(f"document.cookie={json.dumps(js)};")
    for host, lines in by_host.items():
        print(f"== any page under {host}" if host.startswith(".") else f"== https://{host}/")
        print("".join(lines) + "1")

main()
