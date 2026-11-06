"""Kernel OOM kill on a sustained memory stall, before the 30 s watchdog resets the Pi.

earlyoom reads MemAvailable, which stayed at 27-48% in the hour before the
2026-11-05/06 resets, and MGLRU min_ttl_ms=1000 never fires: the oldest
generation was ~28 s old at load 12. PSI `full` measures the stall itself.
When every runnable task waits on memory for STALL_MS out of WINDOW_MS, this
asks the kernel to OOM-kill (sysrq f), which picks by oom_score.
"""

import ctypes
import os
import re
import select
import time

from ..logs import logger
from ..secrets import env_int, env_str

TAG = "psi-oom"

STALL_MS = 4000
WINDOW_MS = 10000
# oom_reaper frees the victim in well under a second; let PSI settle before
# another kill counts against the same stall.
COOLDOWN_SEC = 10

FULL_RE = re.compile(r"^full avg10=([\d.]+)", re.M)

MCL_CURRENT, MCL_FUTURE = 1, 2


class Config:
    pressure: str = "/proc/pressure/memory"
    sysrq: str = "/proc/sysrq-trigger"
    stall_ms: int = STALL_MS
    window_ms: int = WINDOW_MS
    cooldown_sec: int = COOLDOWN_SEC
    dry_run: bool = True

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    @classmethod
    def from_env(cls, env=None):
        return cls(
            pressure=env_str("PSI_OOM_PRESSURE", cls.pressure, env),
            sysrq=env_str("PSI_OOM_SYSRQ", cls.sysrq, env),
            stall_ms=env_int("PSI_OOM_STALL_MS", STALL_MS, env),
            window_ms=env_int("PSI_OOM_WINDOW_MS", WINDOW_MS, env),
            cooldown_sec=env_int("PSI_OOM_COOLDOWN_SEC", COOLDOWN_SEC, env),
            dry_run=env_str("PSI_OOM_DRY_RUN", "1", env) != "0",
        )

    @property
    def trigger(self):
        # The kernel overwrites the last byte written with NUL; without our own
        # NUL it truncates the window (10000000 -> 1000000 < stall) and EINVALs.
        return f"full {self.stall_ms * 1000} {self.window_ms * 1000}\0"


def full_avg10(text):
    m = FULL_RE.search(text)
    return float(m[1]) if m else None


def on_stall(cfg, last_kill, now, *, read, kill, log):
    """Handle one PSI event; return the time of the last kill."""
    if now - last_kill < cfg.cooldown_sec:
        return last_kill
    avg = full_avg10(read())
    if cfg.dry_run:
        log(f"memory stall (full avg10={avg}): would OOM-kill (dry run)")
        return now
    kill()
    log(f"memory stall (full avg10={avg}): asked the kernel to OOM-kill")
    return now


def lock_memory(log):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.mlockall(MCL_CURRENT | MCL_FUTURE) != 0:
        log(f"mlockall failed: {os.strerror(ctypes.get_errno())}")


def main(argv=None, env=None, log=None):
    cfg = Config.from_env(env)
    log = log or logger(TAG)
    # Under thrash this process must not wait on its own pages.
    lock_memory(log)

    fd = os.open(cfg.pressure, os.O_RDWR | os.O_NONBLOCK)
    os.write(fd, cfg.trigger.encode())
    poller = select.poll()
    poller.register(fd, select.POLLPRI)
    log(f"armed: {cfg.trigger.rstrip(chr(0))} on {cfg.pressure}, dry_run={cfg.dry_run}")

    def read():
        with open(cfg.pressure) as f:
            return f.read()

    def kill():
        with open(cfg.sysrq, "w") as f:
            f.write("f")

    last_kill = float("-inf")
    while True:
        for _, ev in poller.poll():
            if ev & select.POLLERR:
                raise SystemExit("PSI trigger closed")
            last_kill = on_stall(
                cfg, last_kill, time.monotonic(), read=read, kill=kill, log=log
            )


if __name__ == "__main__":
    main()
