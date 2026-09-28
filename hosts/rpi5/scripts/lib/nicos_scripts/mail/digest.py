#!/usr/bin/env python3
"""hermes-mail-digest: the daily inbox digest, from the store.

A `no_agent` cron tick: it spends no model tokens, so a plan-cap 429 cannot take
the morning digest down with Hermes. Bullets are therefore sender + trimmed
subject rather than a model-written action phrase.

Each message is classified by Jev exactly once. A re-run costs nothing but the
fetch, which is what makes the store worth having: the verdicts accumulate, and
`surfaced_count` can finally say "you were told about this three days running".

Env: MAIL_DB, MAIL_GMAIL_ACCOUNTS (role=address,…), MAIL_PROTON_ROLE,
MAIL_PROTON_INDEX, MAIL_QUERY, PROTON_USER, PROTON_PASS_FILE, TYPESAFE_*,
TELEGRAM_SEND, TELEGRAM_CHAT_ID.
"""

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, replace
from datetime import datetime, timezone

from ..logs import logger
from ..secrets import env_int, env_str, read_secret
from . import fetch, jev, store

log = logger("hermes-mail-digest", lambda: sys.stderr)

DEFAULT_DB = "/home/nsimon/.mail-digest/mail.db"
DEFAULT_PROTON_USER = "nsimon@protonmail.com"
DEFAULT_QUERY = "in:inbox is:unread"
BACKFILL_QUERY = "in:inbox newer_than:90d"
FOLD_AT = 5          # past this many items a section collapses into <details>
SUBJECT_MAX = 58


@dataclass(frozen=True)
class Config:
    db: str = DEFAULT_DB
    gmail: tuple = ()          # ((role, address), …)
    proton_role: str = "personal"
    proton_index: str = "0"
    proton_user: str = DEFAULT_PROTON_USER
    proton_pass_file: str = "/run/agenix/protonmail-bridge-password"
    query: str = DEFAULT_QUERY
    endpoint: str = jev.DEFAULT_ENDPOINT
    model: str = jev.DEFAULT_MODEL
    limit: int = 400
    top: int = 3
    read: int = 6
    telegram_send: str = ""
    chat_id: str = ""

    @classmethod
    def from_env(cls, env=None):
        pairs = []
        for item in env_str("MAIL_GMAIL_ACCOUNTS", "", env).split(","):
            role, _, addr = item.strip().partition("=")
            if role and addr:
                pairs.append((role, addr))
        return cls(
            db=env_str("MAIL_DB", DEFAULT_DB, env),
            gmail=tuple(pairs),
            proton_role=env_str("MAIL_PROTON_ROLE", "personal", env),
            proton_index=env_str("MAIL_PROTON_INDEX", "0", env),
            proton_user=env_str("PROTON_USER", DEFAULT_PROTON_USER, env),
            proton_pass_file=env_str(
                "PROTON_PASS_FILE", "/run/agenix/protonmail-bridge-password", env),
            query=env_str("MAIL_QUERY", DEFAULT_QUERY, env),
            endpoint=env_str("TYPESAFE_ENDPOINT", jev.DEFAULT_ENDPOINT, env),
            model=env_str("TYPESAFE_MODEL", jev.DEFAULT_MODEL, env),
            limit=env_int("MAIL_MAX", 400, env),
            telegram_send=env_str("TELEGRAM_SEND", "telegram-send", env),
            chat_id=env_str("TELEGRAM_CHAT_ID", "", env),
        )


# ---------------------------------------------------------------- collection


def collect(cfg, query, run=None, connect=None):
    """Every account's envelopes, tagged with role and source.

    A mailbox that cannot be read raises rather than returning nothing: an empty
    result and an unreachable server must not produce the same calm digest.
    """
    out = []
    for role, address in cfg.gmail:
        for row in fetch.gmail(address, query, limit=cfg.limit, run=run):
            row["account"] = role
            out.append(row)
    if cfg.proton_user:
        connect = connect or fetch.imap_connect
        M = connect(fetch.IMAP_HOST, fetch.IMAP_PORT, cfg.proton_user,
                    read_secret(cfg.proton_pass_file))
        try:
            criteria = "ALL" if "newer_than" in query else "UNSEEN"
            for row in fetch.imap(M, criteria,
                                  source=f"proton:{cfg.proton_index}",
                                  limit=cfg.limit):
                row["account"] = cfg.proton_role
                out.append(row)
        finally:
            try:
                M.logout()
            except Exception:  # a failed logout must not lose the fetch
                pass
    return out


def classify_pending(cfg, conn, pending, now, post=None):
    """Run Jev over rows that have never been classified. Returns usage."""
    if not pending:
        return {"messages": 0, "failed": 0, "input_tokens": 0, "usd": 0.0}
    envelopes = [{"id": r["key"], "account": r["account"], "source": r["source"],
                  "threadId": r["thread"], "from": r["sender"],
                  "subject": r["subject"], "date": r["date"],
                  "body": r.get("body", "")} for r in pending]
    kwargs = {"post": post} if post else {}
    results, usage = jev.classify(
        envelopes, jev.resolve_key(), cfg.endpoint, cfg.model, **kwargs)
    for res in results:
        store.save_classification(conn, res["id"], res, cfg.model, now)
    conn.commit()
    return usage


def normalise(env_row):
    """Clean an envelope before it reaches the store.

    gog's --wrap-untrusted wraps every text field, subject included, so an
    unwrapped subject is stored — and printed — as the marker. `threadId` is
    also gog's spelling; without mapping it the thread column stays empty and
    two messages of one thread survive dedupe.
    """
    env_row["subject"] = jev.unwrap(env_row.get("subject") or "")
    env_row["from"] = jev.unwrap(env_row.get("from") or "")
    env_row["thread"] = env_row.get("threadId") or env_row.get("thread") or ""
    env_row["url"] = jev.message_url(env_row, env_row["thread"])
    return env_row


# ---------------------------------------------------------------- rendering


def as_result(row):
    """A store row in the shape `jev.assign` reads.

    The store spells the sender `sender` and keeps the signals in columns; the
    classifier speaks `from` and a nested `signals`. Adapt here rather than
    bending either side.
    """
    out = dict(row)
    out["from"] = row.get("sender") or ""
    out["signals"] = {s: (row.get(s) or 0.0) for s in store.SIGNALS}
    out["rank"] = row.get("rank") or 0.0
    out["disposition"] = row.get("disposition") or "leave"
    out["disposition_confidence"] = row.get("disposition_confidence") or 0.0
    out["subject"] = row.get("subject") or ""
    return out


def trim(row):
    s = re.sub(r"\s+", " ", row["subject"] or "").strip()
    s = re.sub(r"^(Re|Fwd|Fw|Tr)\s*:\s*", "", s, flags=re.I)
    if len(s) > SUBJECT_MAX:
        s = s[: SUBJECT_MAX - 1] + "…"
    sender = re.sub(r"\s*<[^>]*>", "", row["sender"] or "").strip().strip('"')
    return f"{sender} — {s}" if sender else (s or "(no subject)")


def bullet(row):
    label = trim(row).replace("[", "(").replace("]", ")")
    nag = ""
    if (row.get("surfaced_count") or 0) >= 2:
        nag = f" · {row['surfaced_count'] + 1}ᵉ jour"
    return f"- [{label}]({row['url']}){nag}" if row.get("url") else f"- {label}{nag}"


def section(title, emoji, rows):
    if not rows:
        return [f"## {emoji} {title}", "", "- none", ""]
    body = [bullet(r) for r in rows]
    if len(rows) > FOLD_AT:
        return ([f"<details><summary>{emoji} {title} ({len(rows)})</summary>", ""]
                + body + ["", "</details>", ""])
    return [f"## {emoji} {title}", ""] + body + [""]


def render(buckets, counts, today, warning=""):
    lines = [f"# 📬 Daily mail — {today:%A %-d %B}", ""]
    if warning:
        lines += [f"> ⚠️ {warning}", ""]
    lines += section("Top actions", "⚡", buckets["top_actions"])
    lines += section("Read if time", "📖", buckets["read_if_time"])
    cleanup = buckets["delete_spam"] + buckets["archive"]
    lines += [f"<details><summary>🧹 Suggested cleanup ({len(cleanup)})</summary>", ""]
    for name, key in (("Delete/spam", "delete_spam"), ("Archive", "archive")):
        rows = buckets[key]
        items = ", ".join(bullet(r)[2:] for r in rows) if rows else "none"
        lines.append(f"- {name}: {items}")
    lines += ["", "</details>", ""]
    lines += ["| Inbox | Unread | Important |", "|---|---|---|"]
    for role in sorted(counts):
        c = counts[role]
        lines.append(f"| {role.capitalize()} | {c['unread']} | {c['important']} |")
    return "\n".join(lines)


def important_counts(cfg, run=None):
    """Gmail's own is:important, per role — the store does not model it."""
    run = run or subprocess.run
    out = {}
    for role, address in cfg.gmail:
        try:
            rows = fetch.gmail(address, "in:inbox is:important",
                               limit=500, run=run)
            out[role] = out.get(role, 0) + len(rows)
        except fetch.FetchFailed:
            out.setdefault(role, 0)
    return out


def send(cfg, text, run=None):
    run = run or subprocess.run
    cmd = [cfg.telegram_send, "-m", "rich"]
    if cfg.chat_id:
        cmd += ["-c", cfg.chat_id]
    proc = run(cmd, input=text, capture_output=True, text=True, timeout=60)
    return proc.returncode == 0 and '"ok":true' in (proc.stdout or "")


# ---------------------------------------------------------------- entry point


def main(argv=None, env=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--backfill", action="store_true",
                    help="widen to 90 days, read and unread, and do not send")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the digest instead of sending it")
    ap.add_argument("--max", type=int, default=None)
    ap.add_argument("--batch", type=int, default=None,
                    help="classify at most N messages this run (cost control)")
    args = ap.parse_args(argv)

    cfg = Config.from_env(env)
    if args.max:
        cfg = replace(cfg, limit=args.max)
    if not cfg.gmail and not cfg.proton_user:
        log("FATAL: no accounts configured (MAIL_GMAIL_ACCOUNTS / PROTON_USER)")
        return 1
    if not jev.resolve_key():
        log("FATAL: no TYPESAFE_API_KEY")
        return 1

    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    query = BACKFILL_QUERY if args.backfill else cfg.query
    conn = store.connect(cfg.db)

    try:
        envelopes = collect(cfg, query)
    except (fetch.FetchFailed, OSError) as exc:
        log(f"FATAL: {exc}")
        return 1

    for env_row in envelopes:
        normalise(env_row)
    keys = store.upsert_seen(conn, envelopes, now)
    bodies = {store.key_for(e): e.get("body", "") for e in envelopes}

    pending = store.unclassified(conn, limit=args.batch)
    for row in pending:
        row["body"] = bodies.get(row["key"], "")
    usage = classify_pending(cfg, conn, pending, now)
    failed = usage["failed"]
    log(f"fetched {len(envelopes)}, {len(pending)} pending, "
        f"classified {usage['messages']}, failed {failed}, ${usage['usd']:.4f}")

    # "classified 0" is the signature of a healthy re-run AND of a dead API.
    # Only the pending count tells them apart, so branch on it rather than on
    # the count of successes.
    warning = ""
    if failed:
        first = (usage["errors"][0] or {}).get("error", "unknown")
        log(f"WARN: {failed} classification(s) failed — {first}")
        if usage["messages"] == 0:
            # Nothing got through. Exit non-zero: the cron scheduler turns that
            # into a Telegram alert, and stdout is /dev/null'd in the shim.
            log(f"FATAL: no message could be classified ({first})")
            return 1
        warning = f"{failed} message(s) non classé(s) — {first[:120]}"

    if not args.backfill:
        store.reconcile(conn, [r for r, _ in cfg.gmail] + [cfg.proton_role],
                        keys, now)

    if args.backfill:
        log(f"backfill done: {store.spend(conn)}")
        return 0

    ranked = [as_result(r) for r in store.live_ranked(conn)]
    buckets = jev.assign(ranked, top=cfg.top, read=cfg.read)
    counts = {}
    for row in ranked:
        counts.setdefault(row["account"], {"unread": 0, "important": 0})
        counts[row["account"]]["unread"] += 1
    for role, n in important_counts(cfg).items():
        counts.setdefault(role, {"unread": 0, "important": 0})["important"] = n

    text = render(buckets, counts, datetime.now(), warning=warning)
    if args.dry_run:
        print(text)
        return 0

    surfaced = [r["key"] for k in ("top_actions", "read_if_time")
                for r in buckets[k]]
    if not send(cfg, text):
        log("FATAL: telegram send rejected")
        return 1
    store.mark_surfaced(conn, surfaced, now)
    return 0


if __name__ == "__main__":
    sys.exit(main())
