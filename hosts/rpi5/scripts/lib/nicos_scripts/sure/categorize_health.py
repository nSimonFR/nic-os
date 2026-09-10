"""Alert when Sure's AI auto-categorization has work queued that is not moving.

The check this replaces grepped `sure-worker` for "Failed to auto-categorize",
so it could only fire when an `AutoCategorizeJob` RAN and FAILED. On 2026-09-02
the jobs stopped running at all: something re-ran the rules over full history and
pushed ~950 jobs onto `medium_priority`, where `AutoCategorizeJob` shares one
strict-FIFO queue with `AutoDetectMerchantsJob` — 219 categorize jobs landed
behind 691 merchant jobs, each a ~40s LLM call, on a worker that is
socket-activated and lives 2-11 minutes a day. A queued job emits no log line,
so the old check reported success every 15 minutes for eight days while the
`standard` uncategorized count went 142 -> 892.

Reordering that queue was considered and rejected: Sidekiq weights are not
priorities (fetch.rb shuffles a weight-expanded queue list per fetch), and the
binding constraint was never queue order but worker uptime — ~7 min/day against
~7.6h of queued LLM work. `sure-drain-keepalive` addresses the cause; this
detects whatever the next variant turns out to be.

So this asserts on the QUEUE, not the log: categorize jobs exist and the oldest
has been waiting longer than a worker-wake cycle. That is the failure directly —
it does not care why the worker is behind, and it cannot be fooled by a job that
never starts.

Deliberately NOT the alert condition:

- "no `category_id` enrichment written recently" alone. There is a permanent
  residue of genuinely ambiguous transactions (`VIR INSTANTANE ... POUR: <person>`,
  `Unknown transaction`), so a quiet day is normal and would page constantly.
  Reported as context only.
- "N transactions uncategorized" alone. Same reason: that number never reaches
  zero, so any floor is either always tripped or useless.

Emits the alert body on stdout, empty when healthy; the unit pipes that to
telegram-alert, which owns sending and dedup.
"""

import json
from datetime import datetime, timedelta, timezone

from ..logs import logger
from ..pg import psql_rows
from ..secrets import env_int, env_str

TAG = "sure-categorize-health"

DEFAULT_SURE_DB = "sure_production"
DEFAULT_RUNUSER = "runuser"
DEFAULT_PSQL = "psql"
DEFAULT_REDIS_CLI = "redis-cli"
DEFAULT_REDIS_DB = 2
# The worker is socket-activated (idleSec=600) and in practice wakes about once
# a day, so a job enqueued just after a teardown can legitimately wait ~20h.
# 24h still catches an 8-day stall on its first day without paging on normal
# idle behaviour.
DEFAULT_STALE_HOURS = 24
# Where AutoCategorizeJob lives (Sure's app/jobs/auto_categorize_job.rb is
# `queue_as :medium_priority`). Overridable so a future queue rename does not
# silently make this report "nothing queued" — which reads as healthy.
DEFAULT_QUEUES = "medium_priority"

JOB_CLASS = "AutoCategorizeJob"


class Config:
    sure_db: str = DEFAULT_SURE_DB
    runuser: str = DEFAULT_RUNUSER
    psql: str = DEFAULT_PSQL
    redis_cli: str = DEFAULT_REDIS_CLI
    redis_db: int = DEFAULT_REDIS_DB
    stale_hours: int = DEFAULT_STALE_HOURS
    queues: tuple = ()

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    @classmethod
    def from_env(cls, env=None):
        raw = env_str("CATEGORIZE_QUEUES", DEFAULT_QUEUES, env)
        return cls(
            sure_db=env_str("SURE_DB", DEFAULT_SURE_DB, env),
            runuser=env_str("RUNUSER_BIN", DEFAULT_RUNUSER, env),
            psql=env_str("PSQL_BIN", DEFAULT_PSQL, env),
            redis_cli=env_str("REDIS_CLI_BIN", DEFAULT_REDIS_CLI, env),
            redis_db=env_int("REDIS_DB", DEFAULT_REDIS_DB, env),
            stale_hours=env_int("STALE_HOURS", DEFAULT_STALE_HOURS, env),
            queues=tuple(q.strip() for q in raw.split(",") if q.strip()),
        )


# ── reading the queue ────────────────────────────────────────────────────────

def job_created_at(line):
    """Sidekiq's `created_at` for one queue entry, as an aware UTC datetime.

    Sidekiq 8 writes epoch milliseconds; older payloads (and its own docs) use
    float seconds. Discriminate on magnitude rather than trusting either — a ms
    value read as seconds lands in the year 58000 and makes an ancient job look
    like it is from the future, i.e. reports the stall as healthy.
    """
    raw = json.loads(line).get("created_at")
    if raw is None:
        return None
    secs = raw / 1000 if raw > 1e11 else raw
    return datetime.fromtimestamp(secs, timezone.utc)


def queued_categorize(cfg, run):
    """(count, oldest_created_at) for AutoCategorizeJob across `cfg.queues`."""
    count, oldest = 0, None
    for q in cfg.queues:
        out = run([cfg.redis_cli, "-n", str(cfg.redis_db),
                   "lrange", f"queue:{q}", "0", "-1"])
        for line in out.splitlines():
            if JOB_CLASS not in line:
                continue
            count += 1
            try:
                at = job_created_at(line)
            except (ValueError, TypeError):
                # A malformed payload must not mask the jobs around it.
                continue
            if at and (oldest is None or at < oldest):
                oldest = at
    return count, oldest


# ── reading the outcome (context for the body) ───────────────────────────────

def parse_pg_timestamp(value):
    """Postgres `timestamp without time zone`, which Rails stores in UTC."""
    text = (value or "").strip()
    if not text:
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def last_category_write(cfg, run):
    rows = psql_rows(run, """
        SELECT max(created_at) FROM data_enrichments
        WHERE attribute_name = 'category_id'
    """, cfg.sure_db, cfg.runuser, cfg.psql)
    return parse_pg_timestamp(rows[0][0]) if rows else None


def uncategorized_standard(cfg, run):
    """Uncategorized non-transfer transactions.

    `funds_movement` is excluded: the deployed auto-categorize-skip-transfers
    patch correctly refuses to label transfers, so counting them would report a
    permanent several-hundred backlog as a fault.
    """
    rows = psql_rows(run, """
        SELECT count(*) FROM transactions
        WHERE category_id IS NULL AND kind = 'standard'
    """, cfg.sure_db, cfg.runuser, cfg.psql)
    try:
        return int(rows[0][0])
    except (IndexError, ValueError):
        return None


# ── the verdict ──────────────────────────────────────────────────────────────

def hours_since(then, now):
    return None if then is None else (now - then).total_seconds() / 3600.0


def describe_age(hours):
    if hours is None:
        return "never"
    if hours < 48:
        return f"{hours:.1f}h ago"
    return f"{hours / 24:.1f}d ago"


def assess(queued, oldest, last_write, backlog, now, stale_hours):
    """Alert body, or "" when healthy.

    Stalled == categorize jobs are queued AND the oldest has waited longer than
    a worker-wake cycle. An empty queue is healthy by definition: there is
    nothing for the worker to fail at.
    """
    if queued == 0:
        return ""
    waiting = hours_since(oldest, now)
    if waiting is None or waiting <= stale_hours:
        return ""

    lines = [
        f"{queued} {JOB_CLASS} queued, oldest enqueued {describe_age(waiting)} "
        f"(threshold {stale_hours}h)",
        f"last category_id enrichment: {describe_age(hours_since(last_write, now))}",
    ]
    if backlog is not None:
        lines.append(f"uncategorized standard transactions: {backlog}")
    lines.append(
        "queue is not draining — check sure-worker uptime "
        "(sure-drain-keepalive.timer) and the LLM path in sureLlmEnv"
    )
    return "\n".join(lines)


def main(argv=None, env=None, run=None, now=None, log=None):
    import subprocess
    import sys

    cfg = Config.from_env(env)
    # stderr, not stdout: stdout IS the alert body (the unit pipes it straight
    # into telegram-alert), so a healthy-run log line on stdout would page as
    # its own alert.
    log = log or logger(TAG, stream=lambda: sys.stderr)
    if run is None:
        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True,
                                  check=False).stdout
    now = now or datetime.now(timezone.utc)

    queued, oldest = queued_categorize(cfg, run)
    last_write = last_category_write(cfg, run)
    backlog = uncategorized_standard(cfg, run)

    body = assess(queued, oldest, last_write, backlog, now, cfg.stale_hours)
    if body:
        print(body)
    else:
        log(f"ok — {queued} queued, last write "
            f"{describe_age(hours_since(last_write, now))}, backlog {backlog}")
    return 0
