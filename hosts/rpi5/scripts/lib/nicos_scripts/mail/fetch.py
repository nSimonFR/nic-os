"""Envelope collection. Gmail through gog, everything else over IMAP.

Both paths return the same shape, the one `jev.build_state` already reads:
account/source/id/threadId/from/subject/date/body.

Bodies matter. A `gog` search without --include-body returns sender, subject
and date only, and ranking on subject lines alone measurably degrades; the
same was true of IMAP until this stopped going through `himalaya envelope
list`, which carries no body at all.
"""

import email
import imaplib
import json
import subprocess

from ..connectors.travel_cal import body_text, decode_header

IMAP_HOST = "127.0.0.1"
IMAP_PORT = 1143
SOCKET_TIMEOUT = 60

GOG_FIELDS = ("--include-body", "--body-format", "text", "--wrap-untrusted",
              "--json", "--results-only", "--no-input")


class FetchFailed(Exception):
    """A mailbox could not be read. Never confused with 'no new mail'."""


def gmail(account, query, limit=200, run=None):
    run = run or subprocess.run
    cmd = ["gog", "gmail", "messages", "search", query, "--all",
           "--max", str(limit), "--account", account, *GOG_FIELDS]
    proc = run(cmd, capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        raise FetchFailed(f"gog {account}: {(proc.stderr or '').strip()[:200]}")
    try:
        rows = json.loads(proc.stdout or "[]")
    except ValueError as exc:
        raise FetchFailed(f"gog {account}: unparseable output") from exc
    for row in rows:
        row["source"] = f"gmail:{account}"
    return rows


def imap_connect(host, port, user, password, mailbox="INBOX"):
    try:
        M = imaplib.IMAP4(host, port)
        M.socket().settimeout(SOCKET_TIMEOUT)
        M.login(user, password)
        typ, _ = M.select(mailbox, readonly=True)  # never mutate the mailbox
    except (imaplib.IMAP4.error, OSError) as exc:
        raise FetchFailed(f"IMAP {user}@{host}:{port}: {exc}") from exc
    if typ != "OK":
        raise FetchFailed(f"cannot select {mailbox!r}")
    return M


def imap(M, criteria="ALL", source="proton", limit=200):
    """Fetch envelopes with bodies. BODY.PEEK leaves \\Seen alone."""
    try:
        typ, data = M.search(None, criteria)
    except imaplib.IMAP4.error as exc:
        raise FetchFailed(f"IMAP search: {exc}") from exc
    if typ != "OK":
        raise FetchFailed(f"IMAP search failed: {criteria}")
    nums = (data[0] or b"").split()[-limit:]
    out = []
    for num in nums:
        typ, payload = M.fetch(num, "(BODY.PEEK[])")
        if typ != "OK" or not payload or not isinstance(payload[0], tuple):
            continue
        msg = email.message_from_bytes(payload[0][1])
        out.append({
            "id": num.decode(),
            "source": source,
            "from": decode_header(msg.get("From", "")),
            "subject": decode_header(msg.get("Subject", "")),
            "date": msg.get("Date", ""),
            "body": body_text(msg),
        })
    return out
