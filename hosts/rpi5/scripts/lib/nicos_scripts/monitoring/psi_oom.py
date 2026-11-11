"""Act on a sustained memory stall before the 30 s watchdog resets the Pi.

earlyoom reads MemAvailable, which stayed at 27-48% in the hour before the
2026-11-05/06 resets, and MGLRU min_ttl_ms=1000 never fires: the oldest
generation was ~28 s old at load 12. PSI `full` measures the stall itself.
When every runnable task waits on memory for STALL_MS out of WINDOW_MS, this
first freezes nix-daemon if it has a worker (a deploy's substitution: the 26.05
deploy reset the Pi at 16 and at 2 jobs), and thaws it once the trigger stays
quiet. A stall that outlasts the freeze is not the deploy's: it SIGKILLs the
process holding the most anon + swap memory.

Not sysrq f: it picks by oom_score, where T3's agents (adj 800) and
ryot-sandboxd (adj 1000) outrank everything. On 2026-11-11 it killed sleep,
bash and a 1 MiB ryot-sandboxd over and over until the watchdog reset.
"""

import ctypes
import os
import re
import select
import signal
import time

from ..logs import logger
from ..secrets import env_int, env_str

TAG = "psi-oom"

STALL_MS = 4000
WINDOW_MS = 10000
# oom_reaper frees the victim in well under a second; let PSI settle before
# another kill counts against the same stall.
COOLDOWN_SEC = 10
# Killing anything smaller does not end a stall.
MIN_VICTIM_MIB = 64
DEFERRABLE_CGROUP = "/sys/fs/cgroup/system.slice/nix-daemon.service"

FULL_RE = re.compile(r"^full avg10=([\d.]+)", re.M)
STATUS_RE = re.compile(r"^(Name|RssAnon|VmSwap):\s+(\S+)", re.M)

MCL_CURRENT, MCL_FUTURE = 1, 2


class Config:
    pressure: str = "/proc/pressure/memory"
    stall_ms: int = STALL_MS
    window_ms: int = WINDOW_MS
    cooldown_sec: int = COOLDOWN_SEC
    min_victim_mib: int = MIN_VICTIM_MIB
    cgroup: str = DEFERRABLE_CGROUP
    dry_run: bool = True

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    @classmethod
    def from_env(cls, env=None):
        return cls(
            pressure=env_str("PSI_OOM_PRESSURE", cls.pressure, env),
            stall_ms=env_int("PSI_OOM_STALL_MS", STALL_MS, env),
            window_ms=env_int("PSI_OOM_WINDOW_MS", WINDOW_MS, env),
            cooldown_sec=env_int("PSI_OOM_COOLDOWN_SEC", COOLDOWN_SEC, env),
            min_victim_mib=env_int("PSI_OOM_MIN_VICTIM_MIB", MIN_VICTIM_MIB, env),
            cgroup=env_str("PSI_OOM_CGROUP", DEFERRABLE_CGROUP, env),
            dry_run=env_str("PSI_OOM_DRY_RUN", "1", env) != "0",
        )

    @property
    def trigger(self):
        # The kernel overwrites the last byte written with NUL; without our own
        # NUL it truncates the window (10000000 -> 1000000 < stall) and EINVALs.
        return f"full {self.stall_ms * 1000} {self.window_ms * 1000}\0"

    @property
    def thaw_sec(self):
        # The trigger fires at most once per window while a stall lasts, so two
        # quiet windows mean it is over.
        return 2 * self.window_ms / 1000


def full_avg10(text):
    m = FULL_RE.search(text)
    return float(m[1]) if m else None


def parse_status(text):
    """(name, anon + swap KiB) from /proc/<pid>/status; None for kernel threads."""
    fields = dict(STATUS_RE.findall(text))
    if "RssAnon" not in fields:
        return None
    return fields.get("Name", "?"), int(fields["RssAnon"]) + int(
        fields.get("VmSwap", 0)
    )


def scan_procs(root="/proc"):
    """Yield (pid, name, oom_score_adj, anon + swap KiB) for every user process."""
    for entry in os.listdir(root):
        if not entry.isdigit():
            continue
        try:
            with open(f"{root}/{entry}/status") as f:
                parsed = parse_status(f.read())
            with open(f"{root}/{entry}/oom_score_adj") as f:
                adj = int(f.read())
        except (OSError, ValueError):
            continue  # exited mid-scan
        if parsed:
            yield int(entry), parsed[0], adj, parsed[1]


def pick_victim(procs, min_kib, self_pid):
    """Largest anon + swap process not protected by a negative oom_score_adj."""
    best = None
    for pid, name, adj, kib in procs:
        if pid in (1, self_pid) or adj < 0 or kib < min_kib:
            continue
        if best is None or kib > best[2]:
            best = (pid, name, kib)
    return best


class Cgroup:
    """The deferrable work: freezable through cgroup v2, no memory controller needed."""

    def __init__(self, path):
        self.path = path

    def busy(self):
        """A worker besides the daemon itself, i.e. a client is being served."""
        try:
            with open(f"{self.path}/cgroup.procs") as f:
                return len(f.read().split()) > 1
        except OSError:
            return False  # socket-activated and idle

    def freeze(self, on):
        try:
            with open(f"{self.path}/cgroup.freeze", "w") as f:
                f.write("1" if on else "0")
        except OSError:
            pass


class Guard:
    """Freeze the deferrable cgroup first; kill only if the stall outlasts it."""

    def __init__(self, cfg, *, read, procs, kill, deferrable, log):
        self.cfg, self.read, self.procs, self.kill = cfg, read, procs, kill
        self.deferrable, self.log = deferrable, log
        self.last_action = float("-inf")
        self.last_stall = float("-inf")
        self.frozen = False

    def on_stall(self, now):
        self.last_stall = now
        if now - self.last_action < self.cfg.cooldown_sec:
            return
        avg = full_avg10(self.read())
        if not self.frozen and self.deferrable.busy():
            self.last_action = now
            if self.cfg.dry_run:
                self.log(
                    f"memory stall (full avg10={avg}): would freeze nix-daemon (dry run)"
                )
                return
            self.deferrable.freeze(True)
            self.frozen = True
            self.log(f"memory stall (full avg10={avg}): froze nix-daemon")
            return
        self._kill(now, avg)

    def on_quiet(self, now):
        if self.frozen and now - self.last_stall >= self.cfg.thaw_sec:
            self.thaw()

    def thaw(self):
        self.deferrable.freeze(False)
        if self.frozen:
            self.log("stall over: thawed nix-daemon")
        self.frozen = False

    def _kill(self, now, avg):
        victim = pick_victim(self.procs(), self.cfg.min_victim_mib * 1024, os.getpid())
        if victim is None:
            self.log(
                f"memory stall (full avg10={avg}): no process >= {self.cfg.min_victim_mib} MiB"
            )
            self.last_action = now
            return
        pid, name, kib = victim
        what = f"{name} (pid {pid}, {kib // 1024} MiB anon+swap)"
        if self.cfg.dry_run:
            self.log(f"memory stall (full avg10={avg}): would kill {what} (dry run)")
            self.last_action = now
            return
        try:
            self.kill(pid)
        except ProcessLookupError:
            return
        self.log(f"memory stall (full avg10={avg}): killed {what}")
        self.last_action = now


def _exit_on_term(*_):
    raise SystemExit(0)


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

    def kill(pid):
        os.kill(pid, signal.SIGKILL)

    guard = Guard(
        cfg,
        read=read,
        procs=scan_procs,
        kill=kill,
        deferrable=Cgroup(cfg.cgroup),
        log=log,
    )
    # A freeze left by a previous run would hold every nix client forever, and
    # `finally` only runs on SIGTERM once it raises.
    guard.thaw()
    signal.signal(signal.SIGTERM, _exit_on_term)
    try:
        while True:
            events = poller.poll(cfg.window_ms)
            for _, ev in events:
                if ev & select.POLLERR:
                    raise SystemExit("PSI trigger closed")
                guard.on_stall(time.monotonic())
            guard.on_quiet(time.monotonic())
    finally:
        guard.thaw()


if __name__ == "__main__":
    main()
