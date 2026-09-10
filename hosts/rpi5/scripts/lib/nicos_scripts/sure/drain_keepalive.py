"""Hold Sure awake while Sidekiq still has queued work.

`sure-worker` is socket-activated with `policy = "sleepWith"`, so its lifetime is
tied to the web tier: `systemd-socket-proxyd --exit-idle-time=600s` exits after
10 minutes with no HTTP connection, `StopWhenUnneeded` then stops `sure-web`, and
`PartOf` drags the worker down with it. Sidekiq's queue depth is invisible to all
of that — the worker is torn down mid-backlog and only revives when a human next
opens the web UI.

Measured on rpi5 over 2026-09-04..09-08: the worker was awake 2-11 minutes per
wake, once or twice a day — about 7 minutes a day. A rule run had left ~950 jobs
queued, roughly 7.6 hours of continuous LLM work at ~40s per merchant job. So
categorization did not stall because the AI was broken or because of queue
priority; it stalled because the worker gets killed while it still has hours of
work and nothing wakes it back up. Reordering the queue only changes which jobs
go first, not the ~7 min/day of capacity.

The fix needs no new systemd machinery: the proxy's idle timer restarts on every
connection, so one HTTP request to the wake URL inside each idle window keeps the
whole tier — and therefore the worker — alive. This runs on a timer and makes
that request ONLY while queues are non-empty, so the sleep behaviour is intact
whenever there is genuinely nothing to do.

Deliberately only counts Sidekiq's *queues* (Redis lists). `retry`, `schedule`
and `dead` are sorted sets of future-dated or abandoned jobs: `dead` in
particular is permanently non-empty here (46 entries), so counting it would pin
Sure awake forever and quietly undo socket activation.
"""

from ..logs import logger
from ..secrets import env_int, env_str

TAG = "sure-drain-keepalive"

DEFAULT_REDIS_CLI = "redis-cli"
DEFAULT_REDIS_DB = 2
DEFAULT_CURL = "curl"
# The socket-activation proxy's listen address (hosts/rpi5/sure.nix externalPort).
# Must be the PROXY, not the backend: connecting straight to sure-web bypasses
# the proxy and so does not reset --exit-idle-time.
DEFAULT_WAKE_URL = "http://127.0.0.1:13334/sure/up"
# Rails cold start is ~30s and the readyProbe allows 60s, so a wake that has to
# boot Puma needs headroom or every first poke reports failure.
DEFAULT_TIMEOUT = 90
# Sure's config/sidekiq.yml. `scheduled` is a real queue here (sidekiq-cron
# pushes SyncHourlyJob etc. into it), so a backlog there deserves a wake too.
DEFAULT_QUEUES = "scheduled,high_priority,medium_priority,low_priority,default"


class Config:
    redis_cli: str = DEFAULT_REDIS_CLI
    redis_db: int = DEFAULT_REDIS_DB
    curl: str = DEFAULT_CURL
    wake_url: str = DEFAULT_WAKE_URL
    timeout: int = DEFAULT_TIMEOUT
    queues: tuple = ()

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    @classmethod
    def from_env(cls, env=None):
        raw = env_str("SIDEKIQ_QUEUES", DEFAULT_QUEUES, env)
        return cls(
            redis_cli=env_str("REDIS_CLI_BIN", DEFAULT_REDIS_CLI, env),
            redis_db=env_int("REDIS_DB", DEFAULT_REDIS_DB, env),
            curl=env_str("CURL_BIN", DEFAULT_CURL, env),
            wake_url=env_str("WAKE_URL", DEFAULT_WAKE_URL, env),
            timeout=env_int("WAKE_TIMEOUT", DEFAULT_TIMEOUT, env),
            queues=tuple(q.strip() for q in raw.split(",") if q.strip()),
        )


def queue_depths(cfg, run):
    """{queue: pending} for each of `cfg.queues`, via LLEN.

    A queue whose LLEN does not parse maps to None rather than 0: an
    unreachable or restarting Redis reads exactly like an empty queue, and
    treating it as empty would let the worker sleep through a real backlog —
    the silent failure this whole unit exists to prevent.
    """
    depths = {}
    for q in cfg.queues:
        out = run([cfg.redis_cli, "-n", str(cfg.redis_db), "llen", f"queue:{q}"])
        try:
            depths[q] = int((out or "").strip())
        except ValueError:
            depths[q] = None
    return depths


def summarize(depths):
    """Only the non-empty queues, biggest first — the journal line's payload."""
    busy = sorted(((q, n) for q, n in depths.items() if n),
                  key=lambda kv: -kv[1])
    return ", ".join(f"{q}={n}" for q, n in busy)


def wake(cfg, run):
    run([cfg.curl, "-s", "-o", "/dev/null",
         "--max-time", str(cfg.timeout), cfg.wake_url])


def main(argv=None, env=None, run=None, log=None):
    import subprocess

    cfg = Config.from_env(env)
    log = log or logger(TAG)
    if run is None:
        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True,
                                  check=False).stdout

    depths = queue_depths(cfg, run)

    unreadable = [q for q, n in depths.items() if n is None]
    if unreadable:
        # Fail loudly instead of guessing. systemd records it and the
        # systemd-failed alert picks it up; guessing "empty" here is what a
        # silent multi-day stall looks like.
        log(f"FATAL cannot read queue depth for: {', '.join(unreadable)}")
        return 1

    total = sum(depths.values())
    if total == 0:
        log("nothing queued — letting Sure sleep")
        return 0

    wake(cfg, run)
    log(f"{total} jobs pending ({summarize(depths)}) — held awake")
    return 0
