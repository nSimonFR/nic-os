#!/usr/bin/env python3
"""Queue local file(s) for ingestion into Papra.

Drops the file(s) into the nsimon-writable staging dir (default
/var/lib/papra/skill-inbox); the root papra-inbox-watch feeder relays them into
Papra's ingestion drop-zone, where Papra ingests them and the on-prem tag sweeper
tags them. No network upload, no API key — purely local handoff.
"""
import os
import re
import shutil
import sys

DROP = os.environ.get("PAPRA_SKILL_INBOX", "/var/lib/papra/skill-inbox")


def safe_name(p):
    b = os.path.basename(p.rstrip("/"))
    b = re.sub(r"[^A-Za-z0-9._ -]", "_", b) or "document"
    return b


def main(argv):
    if not argv:
        print("usage: papra_ingest.py <file> [<file> ...]", file=sys.stderr)
        return 2
    if not os.path.isdir(DROP):
        print(f"error: Papra staging dir {DROP} not present (is the rpi5 config deployed?)",
              file=sys.stderr)
        return 1
    n = 0
    for p in argv:
        if not os.path.isfile(p):
            print(f"skip (not a file): {p}", file=sys.stderr)
            continue
        dest = os.path.join(DROP, safe_name(p))
        base, ext = os.path.splitext(dest)
        i = 1
        while os.path.exists(dest):
            dest = f"{base}-{i}{ext}"
            i += 1
        shutil.copy2(p, dest)
        print(f"queued: {os.path.basename(dest)}")
        n += 1
    print(f"done: {n} file(s) queued for Papra (ingests + auto-tags on-prem within ~2-3 min)")
    return 0 if n else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
