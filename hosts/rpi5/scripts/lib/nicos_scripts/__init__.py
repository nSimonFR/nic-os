"""Shared helpers for the nic-os rpi5 scripts.

Every module here exists because the same code was pasted into three or more
scripts (see the architecture review: `log()` had nine independent definitions,
`http_json`/`load_json`/`save_json`/`post_to_ryot` were byte-identical between
the Steam and Spotify connectors).

Two rules keep this testable off-host:

  * No side effects at import time. No file opens, no `os.environ[...]`, no
    module-level constants that pin a path to this one machine. Config is read
    in `main()` and passed down.
  * Every I/O call takes an injectable seam (`opener=`, `sleep=`, `log=`) whose
    default is the real thing. Prod passes nothing; tests pass a fake.
"""

__all__ = [
    "httpjson",
    "logs",
    "ryot",
    "secrets",
    "state",
]
