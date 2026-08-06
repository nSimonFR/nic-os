"""Idempotency state on disk: read-or-default, write-atomically.

Every connector keeps a cursor/known-set under $STATE_DIR. A half-written state
file is worse than a missing one (it re-pushes, or skips, everything), so writes
go through a temp file + `os.replace`.
"""

import json
import os


def load_json(path, default):
    """Return the parsed file, or `default` when absent/corrupt.

    Corrupt-as-default is deliberate: a truncated cursor file must not wedge a
    timer unit forever. The connector rebuilds it on the next successful run.
    """
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return default


def save_json(path, data, indent=None, sort_keys=False):
    """Write `data` atomically. `indent`/`sort_keys` for the files a human reads."""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=indent, sort_keys=sort_keys)
    os.replace(tmp, path)


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
    return path
