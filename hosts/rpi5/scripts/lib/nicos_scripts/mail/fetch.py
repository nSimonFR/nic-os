"""Envelope collection over IMAP: Gmail with an app password, Proton through hydroxide.

Both paths return the same shape, the one `jev.build_state` already reads:
account/source/id/threadId/from/subject/date/body.

Bodies matter: ranking on subject lines alone measurably degrades, so every
message is fetched whole (BODY.PEEK, which leaves \\Seen alone).
"""

import email
import imaplib
import re

from ..connectors.travel_cal import body_text, decode_header

IMAP_HOST = "127.0.0.1"
IMAP_PORT = 1143
GMAIL_HOST = "imap.gmail.com"
GMAIL_PORT = 993
SOCKET_TIMEOUT = 60

# Gmail ids over IMAP are the decimal form of the hex ids its web UI and API use
# (and gog used, so the store's existing `gmail:<hex>` keys stay valid).
_GM_ATTR = re.compile(rb"X-GM-(MSGID|THRID) (\d+)")
_LIST_LINE = re.compile(rb'\((?P<flags>[^)]*)\) "[^"]*" (?P<name>.+)$')


class FetchFailed(Exception):
    """A mailbox could not be read. Never confused with 'no new mail'."""


def quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def all_mail(listing):
    """The `\\All` mailbox from a LIST reply; its name is localised ("Tous les messages")."""
    for line in listing or []:
        m = _LIST_LINE.match(line or b"")
        if m and b"\\All" in m.group("flags").split():
            return m.group("name").decode()
    raise FetchFailed("no \\All mailbox: is 'Show in IMAP' off for All Mail?")


def gmail_connect(user, password, host=GMAIL_HOST, port=GMAIL_PORT):
    """Gmail on All Mail, read-only: X-GM-RAW only searches the selected folder,
    and `in:inbox` / `is:important` must see every message to filter them."""
    try:
        M = imaplib.IMAP4_SSL(host, port, timeout=SOCKET_TIMEOUT)
        M.login(user, password)
        typ, listing = M.list()
        if typ != "OK":
            raise FetchFailed(f"LIST failed for {user}")
        typ, _ = M.select(all_mail(listing), readonly=True)
    except (imaplib.IMAP4.error, OSError) as exc:
        raise FetchFailed(f"IMAP {user}@{host}:{port}: {exc}") from exc
    if typ != "OK":
        raise FetchFailed(f"cannot select All Mail for {user}")
    return M


def _gmail_uids(M, query):
    try:
        typ, data = M.uid("SEARCH", "X-GM-RAW", quote(query))
    except imaplib.IMAP4.error as exc:
        raise FetchFailed(f"Gmail search {query!r}: {exc}") from exc
    if typ != "OK":
        raise FetchFailed(f"Gmail search failed: {query!r}")
    return (data[0] or b"").split()


def gmail_count(M, query):
    return len(_gmail_uids(M, query))


def gmail(M, query, account, limit=200):
    """Messages matching a Gmail search (`in:inbox is:unread`), newest `limit`."""
    out = []
    for uid in _gmail_uids(M, query)[-limit:]:
        typ, payload = M.uid("FETCH", uid, "(X-GM-MSGID X-GM-THRID BODY.PEEK[])")
        if typ != "OK" or not payload or not isinstance(payload[0], tuple):
            continue
        head, raw = payload[0]
        attrs = dict(_GM_ATTR.findall(head))
        if b"MSGID" not in attrs:
            continue
        msg = email.message_from_bytes(raw)
        out.append(
            {
                "id": format(int(attrs[b"MSGID"]), "x"),
                "threadId": format(int(attrs.get(b"THRID", attrs[b"MSGID"])), "x"),
                "source": f"gmail:{account}",
                "from": decode_header(msg.get("From", "")),
                "subject": decode_header(msg.get("Subject", "")),
                "date": msg.get("Date", ""),
                "body": body_text(msg),
            }
        )
    return out


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
        out.append(
            {
                "id": num.decode(),
                "source": source,
                "from": decode_header(msg.get("From", "")),
                "subject": decode_header(msg.get("Subject", "")),
                "date": msg.get("Date", ""),
                "body": body_text(msg),
            }
        )
    return out
