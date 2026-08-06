"""Environment + agenix secret plumbing.

Four different idioms for "read /run/agenix/<name>" existed across the scripts,
two of them at module level (so the file could not even be imported off-host).
`env` is always a parameter defaulting to `os.environ`, so tests never touch the
process environment.
"""

import os
from pathlib import Path


def env_str(name, default="", env=None):
    return (os.environ if env is None else env).get(name, default)


def env_int(name, default, env=None):
    """Read an int, falling back to `default` on unset/blank/garbage.

    A malformed value in an EnvironmentFile should not crash a timer unit before
    it can log anything useful.
    """
    raw = env_str(name, "", env).strip()
    try:
        return int(raw)
    except ValueError:
        return default


def missing_env(names, env=None):
    """Names from `names` that are unset or empty — for the FATAL preflight."""
    src = os.environ if env is None else env
    return [n for n in names if not src.get(n)]


def read_secret(path):
    """Read an agenix secret file, stripping the trailing newline `age` leaves."""
    return Path(path).read_text().strip()


def read_secret_env(name, default_path=None, env=None):
    """Read the secret whose *path* is in `$name` (agenix convention).

    Returns None when neither the variable nor `default_path` resolves to a
    readable file, so callers can degrade instead of raising at import.
    """
    path = env_str(name, "", env) or default_path
    if not path:
        return None
    try:
        return read_secret(path)
    except OSError:
        return None
