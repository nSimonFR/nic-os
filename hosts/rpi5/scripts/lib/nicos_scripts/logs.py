"""Tagged stdout logging — the one that had nine copies.

    log = logger("steam-to-ryot")
    log("done")           # -> [steam-to-ryot] done

`flush=True` matters: these run as systemd oneshots, and an unflushed buffer on
a `sys.exit(1)` path loses the line that says why.
"""

import sys


def logger(tag, stream=None):
    """Return a `log(msg)` that prefixes `[tag]` and flushes immediately.

    `stream` may be a file object, or a zero-arg callable returning one. Use the
    callable form for `sys.stderr`/`sys.stdout` so the stream is resolved per call
    — pytest (and anything else that swaps those objects) then sees the output.
    """

    def log(msg):
        target = stream() if callable(stream) else stream
        print(f"[{tag}] {msg}", file=target or sys.stdout, flush=True)

    return log
