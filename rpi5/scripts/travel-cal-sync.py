#!/usr/bin/env python3
"""travel-cal-sync — event-driven Proton → Nextcloud travel-booking calendar sync.

Reads Proton over the local hydroxide IMAP bridge (same creds/pattern as
`papra-proton-poll.py`), detects travel bookings (Airbnb / hotels / flights /
trains) with the local `tiny-llm-gate`, and writes each as a VEVENT into a
Nextcloud calendar over CalDAV. Each booking gets a stable UID, so the PUT is
idempotent — re-runs update in place and never create duplicates, even if the
state file is lost.

Runs as a persistent daemon: a catch-up scan on every (re)connect (first run =
backfill over LOOKBACK_DAYS), then IMAP IDLE — waking the moment new mail lands.
A periodic re-scan (RESCAN_SECONDS) is the safety net for any missed IDLE push.
The mailbox is opened READ-ONLY and never mutated (your read/unread state is
untouched); processed messages are tracked by Message-ID in a state file.

Stdlib only (imaplib + urllib) — no third-party deps.

Modes:
  (default)          daemon: scan + IDLE loop.
  --dry-run          one scan, print detected bookings, exit. NO CalDAV writes;
                     needs only the Proton password + tiny-llm-gate (no Nextcloud
                     credential) — safe to run before that secret exists.
  --list-calendars   PROPFIND the Nextcloud calendar home and print each
                     calendar's URI + display name, then exit.

Config via env (defaults suit rpi5):
  PROTON_USER           default nsimon@protonmail.com
  PROTON_PASS_FILE      default /run/agenix/protonmail-bridge-password
  PROTON_MAILBOX        default "All Mail"
  TINY_LLM_GATE_URL     default http://127.0.0.1:4001
  MODEL                 default auto
  LOOKBACK_DAYS         default 365
  STATE_DIR             default /var/lib/travel-cal-sync
  RESCAN_SECONDS        default 1200   (IDLE refresh / safety-net rescan)
  NEXTCLOUD_CALDAV_URL  default https://rpi5.gate-mintaka.ts.net/nextcloud/remote.php/dav/calendars/nsimon/
  NEXTCLOUD_USER        default nsimon
  NEXTCLOUD_PASS_FILE   default /run/agenix/travel-cal-nextcloud-password
  NEXTCLOUD_CAL         calendar collection URI (required for live writes)
  TELEGRAM_TOKEN_FILE   default /run/agenix/telegram-bot-token
  TELEGRAM_CHAT_ID      Telegram chat id (optional; no summary if unset)
"""
import base64
import email
import email.header
import email.utils
import hashlib
import html
import imaplib
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

# ── config ──────────────────────────────────────────────────────────────────
IMAP_HOST = "127.0.0.1"
IMAP_PORT = 1143
PROTON_USER = os.environ.get("PROTON_USER", "nsimon@protonmail.com")
PROTON_PASS_FILE = os.environ.get("PROTON_PASS_FILE", "/run/agenix/protonmail-bridge-password")
MAILBOX = os.environ.get("PROTON_MAILBOX", "All Mail")

GATE = os.environ.get("TINY_LLM_GATE_URL", "http://127.0.0.1:4001").rstrip("/")
MODEL = os.environ.get("MODEL", "auto")

LOOKBACK_DAYS = int(os.environ.get("LOOKBACK_DAYS", "365"))
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/travel-cal-sync")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
RESCAN_SECONDS = int(os.environ.get("RESCAN_SECONDS", "1200"))
# Socket timeout for normal IMAP commands, so a black-holed connection surfaces
# as an error the reconnect loop can handle instead of blocking forever.
SOCKET_TIMEOUT = 300
IDLE_DRAIN_TIMEOUT = 60  # finite timeout for the IDLE DONE-drain

CALDAV_HOME = os.environ.get(
    "NEXTCLOUD_CALDAV_URL",
    "https://rpi5.gate-mintaka.ts.net/nextcloud/remote.php/dav/calendars/nsimon/",
).rstrip("/") + "/"
NC_USER = os.environ.get("NEXTCLOUD_USER", "nsimon")
NC_PASS_FILE = os.environ.get("NEXTCLOUD_PASS_FILE", "/run/agenix/travel-cal-nextcloud-password")
NC_CAL = os.environ.get("NEXTCLOUD_CAL", "")
# Nextcloud web base (for calendar deep links), derived from the CalDAV URL:
# https://host/nextcloud/remote.php/dav/... -> https://host/nextcloud
NC_WEB = CALDAV_HOME.split("/remote.php")[0]

TG_TOKEN_FILE = os.environ.get("TELEGRAM_TOKEN_FILE", "/run/agenix/telegram-bot-token")
TG_CHAT = os.environ.get("TELEGRAM_CHAT_ID", "")

# Link put in each event's description pointing back at the source mailbox. Proton
# search is client-side with no per-message URL scheme (and hydroxide exposes no
# Proton message id), so this can only open Proton Mail — the subject/date in the
# description is what lets you find the exact message (local search).
PROTON_MAIL_URL = os.environ.get("PROTON_MAIL_URL", "https://mail.proton.me/u/2/all-mail")

# Senders whose mail is worth handing to the LLM. Substring match on the From
# address. Broad on purpose — the LLM guardrail is what actually decides.
SENDER_DOMAINS = (
    "airbnb.", "booking.com", "hotels.com", "expedia.", "agoda.com",
    "marriott.", "accor.", "hilton.", "ihg.com", "vrbo.com", "abritel.",
    "airfrance.", "klm.", "easyjet.", "ryanair.", "transavia.",
    "lufthansa.", "ba.com", "britishairways.", "vueling.", "wizzair.",
    "sncf.", "oui.sncf", "sncf-connect.", "trainline.", "thetrainline.",
    "eurostar.", "flixbus.", "blablacar.", "renfe.", "trenitalia.",
)
# Subject keywords (any language we care about) as a fallback net.
SUBJECT_RE = re.compile(
    r"reservation|réservation|reservación|booking|confirmed|confirmation|"
    r"itinerary|itinéraire|check-?in|billet|e-?ticket|boarding|"
    r"your (trip|stay|flight|train)|réserv",
    re.I,
)
# "Queries" — NOT confirmed bookings: inquiries, pending/unconfirmed reservation
# requests, saved searches, price alerts, pre-approvals. Skipped deterministically
# (regardless of the model), so e.g. Airbnb host "Inquiry"/"Pending: Reservation
# Request" mail never becomes an event, while "Reservation confirmed" still does.
NEGATIVE_SUBJECT_RE = re.compile(
    r"\binquir|request to book|reservation request|réservation en attente|"
    r"\bpending\b|en attente|pre-?approve|pré-?approu|saved search|"
    r"recherche enregistr|wishlist|price alert|alerte prix|demande de réservation",
    re.I,
)

TRAVEL_TYPES = {"stay", "flight", "train", "bus", "ferry", "car"}

# Map a sender to a human platform label shown on the event (title prefix +
# iCal CATEGORIES) — e.g. an Airbnb reservation reads as "Airbnb".
SOURCE_PLATFORMS = (
    ("airbnb.", "Airbnb"), ("booking.com", "Booking.com"), ("hotels.com", "Hotels.com"),
    ("expedia.", "Expedia"), ("agoda.", "Agoda"), ("vrbo.", "Vrbo"), ("abritel.", "Abritel"),
    ("marriott.", "Marriott"), ("accor.", "Accor"), ("hilton.", "Hilton"), ("ihg.com", "IHG"),
    ("thetrainline.", "Trainline"), ("trainline.", "Trainline"),
    ("sncf-connect.", "SNCF Connect"), ("oui.sncf", "SNCF"), ("sncf.", "SNCF"),
    ("eurostar.", "Eurostar"), ("flixbus.", "FlixBus"), ("blablacar.", "BlaBlaCar"),
    ("renfe.", "Renfe"), ("trenitalia.", "Trenitalia"),
    ("airfrance.", "Air France"), ("klm.", "KLM"), ("easyjet.", "easyJet"),
    ("ryanair.", "Ryanair"), ("transavia.", "Transavia"), ("lufthansa.", "Lufthansa"),
    ("vueling.", "Vueling"), ("wizzair.", "Wizz Air"),
    ("britishairways.", "British Airways"), ("ba.com", "British Airways"),
)


def source_platform(frm):
    frm = (frm or "").lower()
    for sub, label in SOURCE_PLATFORMS:
        if sub in frm:
            return label
    return ""

SYSTEM_PROMPT = (
    "You extract TRAVEL bookings from a single email. A travel booking is "
    "lodging (hotel/Airbnb/rental), a flight, a train, a bus/coach, a ferry, or "
    "a rental car. Activities, restaurants, events, tickets to attractions, "
    "laser tag, concerts, etc. are NOT travel — return is_booking=false for "
    "those. Reply with ONLY a JSON object, no prose, no markdown fences. Schema:\n"
    "{\n"
    '  "is_booking": bool,      // true ONLY for a CONFIRMED travel reservation with concrete dates\n'
    '  "type": "stay|flight|train|bus|ferry|car",\n'
    '  "title": str,            // If someone is staying at the RECIPIENT\'S OWN place\n'
    "                           // (a host reservation), use the GUEST'S NAME, e.g.\n"
    '                           // "Mélissa Manté — Zen 2-Room Flat". For the recipient\'s\n'
    '                           // own trip, use route/flight/lodging, e.g. "OUIGO\n'
    '                           // Paris→Brest", "Flight AF1234 CDG→LIS", "Airbnb — Lisbon".\n'
    '  "location": str,         // address / city / airports; "" if unknown\n'
    '  "start": str,            // ISO 8601. stays: check-in DATE (YYYY-MM-DD).\n'
    "                           // flights/trains: departure datetime (YYYY-MM-DDTHH:MM, local)\n"
    '  "end": str,              // ISO 8601. stays: check-out DATE. transit: arrival datetime; "" if unknown\n'
    '  "all_day": bool,         // true for stays; false for flights/trains\n'
    '  "checkin_time": str,     // STAYS only: check-in/arrival time HH:MM (24h) if the\n'
    '                           // email states it, e.g. "16:00"; "" if unknown\n'
    '  "checkout_time": str,    // STAYS only: check-out/departure time HH:MM; "" if unknown\n'
    '  "confirmation_code": str,// booking/confirmation ref; "" if none\n'
    '  "notes": str             // short extra detail; "" if none\n'
    "}\n"
    "If the email is marketing, a reminder, a receipt, a review request, or a "
    "message about a PAST trip, or anything that is not a concrete confirmed "
    'booking, return {"is_booking": false}. Extract the dates of the trip the '
    "email is about; never invent dates."
)

# Only upcoming travel is calendar-worthy. A booking whose trip already ended
# (with a small grace) is dropped — this discards the review-requests, receipts
# and re-sent itineraries about past trips that recent mail is full of.
PAST_GRACE_DAYS = 2


# ── small utils ─────────────────────────────────────────────────────────────
def log(*a):
    print(*a, file=sys.stderr, flush=True)


def read_file(path):
    with open(path) as fh:
        return fh.read().strip()


def decode_header(s):
    """Decode an RFC 2047 header (=?utf-8?...?=) so encoded subjects match the
    candidate regex and reach the model as real text, not mojibake."""
    if not s:
        return ""
    try:
        return str(email.header.make_header(email.header.decode_header(s)))
    except Exception:  # noqa: BLE001
        return s


def load_state():
    try:
        with open(STATE_FILE) as fh:
            s = json.load(fh)
    except (FileNotFoundError, ValueError):
        s = {}
    s.setdefault("seen", [])       # processed Message-IDs
    s.setdefault("last_scan", 0)   # epoch of last successful scan
    return s


def save_state(s):
    os.makedirs(STATE_DIR, exist_ok=True)
    # Keep the seen-set bounded but comfortably larger than any plausible
    # rescan-window (SINCE last_scan-2d) message count, so an in-window Message-ID
    # is never evicted and reprocessed. (Re-processing is idempotent anyway via
    # the stable UID, but this avoids wasted LLM/CalDAV calls.)
    s["seen"] = s["seen"][-20000:]
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(s, fh)
    os.replace(tmp, STATE_FILE)


# ── IMAP ────────────────────────────────────────────────────────────────────
def imap_connect():
    M = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)
    M.socket().settimeout(SOCKET_TIMEOUT)  # login/select/search/fetch can't hang forever
    M.login(PROTON_USER, read_file(PROTON_PASS_FILE))
    mbox = f'"{MAILBOX}"' if " " in MAILBOX else MAILBOX
    typ, _ = M.select(mbox, readonly=True)
    if typ != "OK":
        raise RuntimeError(f"cannot select mailbox {MAILBOX!r}")
    return M


def fetch_headers(M, ids, chunk=500):
    """Batch-fetch minimal headers for all message numbers → {num: email.Message}.
    One IMAP round-trip per `chunk` messages (vs. one per message)."""
    out = {}
    for i in range(0, len(ids), chunk):
        batch = b",".join(ids[i:i + chunk])
        typ, data = M.fetch(batch, "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT MESSAGE-ID)])")
        if typ != "OK":
            continue
        for item in data:
            if not isinstance(item, tuple):
                continue
            m = re.match(rb"(\d+)", item[0])
            if m:
                out[m.group(1).decode()] = email.message_from_bytes(item[1])
    return out


def is_candidate(frm, subject):
    frm = (frm or "").lower()
    if any(dom in frm for dom in SENDER_DOMAINS):
        return True
    return bool(subject and SUBJECT_RE.search(subject))


def body_text(msg):
    """Best-effort plain-text body; strip HTML if that's all we have."""
    plain, htmltext = None, None
    for part in msg.walk():
        ct = part.get_content_type()
        if part.get("Content-Disposition", "").lower().startswith("attachment"):
            continue
        if ct == "text/plain" and plain is None:
            plain = _decode(part)
        elif ct == "text/html" and htmltext is None:
            htmltext = _decode(part)
    text = plain or _strip_html(htmltext or "")
    return re.sub(r"\n{3,}", "\n\n", text).strip()[:12000]  # keep both legs of a round-trip


def _decode(part):
    payload = part.get_payload(decode=True) or b""
    return payload.decode(part.get_content_charset() or "utf-8", "replace")


def _strip_html(s):
    s = re.sub(r"(?is)<(script|style).*?</\1>", " ", s)
    s = re.sub(r"(?is)<br\s*/?>", "\n", s)
    s = re.sub(r"(?is)</(p|div|tr|li|h[1-6])>", "\n", s)
    s = re.sub(r"(?is)<[^>]+>", " ", s)
    return html.unescape(s)


# ── extraction via tiny-llm-gate ────────────────────────────────────────────
class UpstreamDown(Exception):
    """The LLM gate / local model is unreachable (e.g. beast asleep). Signals the
    daemon to back off rather than hammer every candidate."""


def extract_booking(text):
    body = json.dumps({
        "model": MODEL,
        "temperature": 0,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": text},
        ],
    }).encode()
    req = urllib.request.Request(
        f"{GATE}/v1/chat/completions",
        data=body,
        headers={"Authorization": "Bearer ollama", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            content = json.load(r)["choices"][0]["message"]["content"]
    except urllib.error.HTTPError as e:
        # 502/503/504 = gate reached but the (local) model upstream is down.
        if e.code in (502, 503, 504):
            raise UpstreamDown(f"gate {e.code}") from e
        raise
    except urllib.error.URLError as e:
        raise UpstreamDown(f"gate unreachable: {e.reason}") from e
    except (TimeoutError, socket.timeout) as e:
        # Slow/asleep model host — treat like upstream-down so the daemon backs
        # off instead of skipping this message as a one-off extract error.
        raise UpstreamDown(f"gate timeout: {e}") from e
    data = _parse_json(content)
    # Normalise to a list of booking dicts: an email may hold several legs (a
    # round-trip = two flights), so the model may return an array — or wrap the
    # array under a key.
    if isinstance(data, dict):
        for k in ("bookings", "results", "items", "data"):
            if isinstance(data.get(k), list):
                return [x for x in data[k] if isinstance(x, dict)]
        return [data]
    if isinstance(data, list):
        return [x for x in data if isinstance(x, dict)]
    return []


def _parse_json(content):
    content = content.strip()
    if content.startswith("```"):
        content = re.sub(r"^```[a-z]*\n?|\n?```$", "", content).strip()
    try:
        return json.loads(content)
    except ValueError:
        pass
    # Fallback: pull the first JSON array or object out of surrounding prose.
    # Must never raise — a raise here would deterministically reprocess the email
    # on every scan (temperature=0 → identical bad output forever).
    for pat in (r"\[.*\]", r"\{.*\}"):
        m = re.search(pat, content, re.S)
        if m:
            try:
                return json.loads(m.group(0))
            except ValueError:
                continue
    return None


# ── iCalendar / CalDAV ──────────────────────────────────────────────────────
def esc(s):
    return ((s or "").replace("\\", "\\\\").replace(";", "\\;")
            .replace(",", "\\,").replace("\r", "").replace("\n", "\\n"))


def _fold(line):
    """Fold an iCalendar content line to <=75 octets (RFC 5545), never splitting a
    multi-byte UTF-8 char. Continuation lines start with a single space."""
    if len(line.encode()) <= 75:
        return line
    out, cur, cur_len = [], "", 0
    for ch in line:
        n = len(ch.encode())
        limit = 75 if not out else 74  # continuation lines carry a leading space
        if cur_len + n > limit:
            out.append(cur)
            cur, cur_len = ch, n
        else:
            cur += ch
            cur_len += n
    out.append(cur)
    return "\r\n ".join(out)


def _parse_dt(value, all_day):
    """Parse a booking date/datetime. Raises ValueError on unparseable input."""
    return datetime.fromisoformat(value[:10]).date() if all_day \
        else datetime.fromisoformat(value)


def _fmt_dt(dt, all_day):
    """Format a date/datetime as an iCal DTSTART/DTEND value fragment."""
    if all_day:
        return ";VALUE=DATE:" + dt.strftime("%Y%m%d")
    if dt.tzinfo is not None:
        return ":" + dt.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return ":" + dt.strftime("%Y%m%dT%H%M%S")  # floating local time


def roll_year_forward(b, received_date):
    """Booking emails often write the trip date without a year ('lundi 3 août'),
    and a small model then guesses a past year → the event gets filtered as past.
    Deterministic local fix: if a date is before the email arrived, roll its year
    forward to the next occurrence on/after the received date. Only applied to
    recently-received mail (see caller) so it can't promote a genuine old trip."""
    for key in ("start", "end"):
        v = b.get(key)
        if not v:
            continue
        all_day = bool(b.get("all_day"))
        try:
            dt = datetime.fromisoformat(v[:10] if all_day else v)
        except ValueError:
            continue
        # Only correct a clearly-stale year (a PRIOR calendar year, the tell-tale
        # of a dropped year), not a same-year recent-past date — that could be a
        # genuinely past trip, which the past-filter should drop rather than promote.
        guard = 0
        while dt.year < received_date.year and dt.date() < received_date and guard < 6:
            try:
                dt = dt.replace(year=dt.year + 1)
            except ValueError:  # Feb 29 → Feb 28
                dt = dt.replace(year=dt.year + 1, day=28)
            guard += 1
        b[key] = dt.strftime("%Y-%m-%d") if all_day else dt.strftime("%Y-%m-%dT%H:%M")


def booking_uid(b):
    # Natural identity of a booking, chosen so the confirmation / reminder /
    # itinerary emails for ONE trip collapse to a single UID (confirmation codes
    # are often absent from some of those emails, so they can't be the identity).
    typ = b.get("type", "x")
    start = b.get("start") or ""
    end = b.get("end") or ""
    if typ == "stay":
        # Lodging: identified by its dates. Reminder emails vary in wording but
        # share dates. (Two unrelated stays with identical check-in AND check-out
        # dates would collide — rare enough to accept.)
        key = f"stay|{start[:10]}|{end[:10]}"
    else:
        # Transit: one day can hold several legs (A->B then B->C), so dates alone
        # are not unique. Key on the full departure+arrival datetimes, which
        # differ between legs but are stable across reminders of the same leg.
        key = f"{typ}|{start}|{end}"
    return f"travelcal-{typ}-{hashlib.sha1(key.encode()).hexdigest()[:12]}@nic-os"


def build_ics(b, uid):
    """Build a VCALENDAR string. Raises ValueError if start/end are unparseable
    (the caller treats that as a permanent skip, not a transient write failure).
    Guarantees DTEND > DTSTART so sabre-dav/Nextcloud never rejects the event."""
    typ = b.get("type")
    all_day = bool(b.get("all_day"))
    start_raw = b["start"]
    end_raw = b.get("end") or ""
    ci = (b.get("checkin_time") or "").strip()
    co = (b.get("checkout_time") or "").strip()
    tm = re.compile(r"^\d{1,2}:\d{2}$")
    # Stays: if the email gave check-in AND check-out times, emit a TIMED event so
    # the arrival and departure times show, instead of an all-day block.
    if typ == "stay" and tm.match(ci) and tm.match(co) and end_raw:
        all_day = False
        start_raw = f"{start_raw[:10]}T{ci}"
        end_raw = f"{end_raw[:10]}T{co}"
    start = _parse_dt(start_raw, all_day)
    end = _parse_dt(end_raw, all_day) if end_raw else None
    # Guarantee a positive duration (all-day DTEND is exclusive; a zero-length or
    # reversed span — e.g. tz-confused transit — is rejected by the server).
    default = timedelta(days=1) if all_day else timedelta(hours=2)
    try:
        bad = end is None or end <= start
    except TypeError:  # e.g. one side tz-aware, the other naive
        bad = True
    if bad:
        end = start + default
    # Title prefixed with the source platform, e.g. "Airbnb · Mélissa Manté — …".
    title = b.get("title") or "Travel booking"
    platform = b.get("_platform") or ""
    summary = f"{platform} · {title}" if platform and platform.lower() not in title.lower() else title
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//nic-os//travel-cal-sync//EN",
        "BEGIN:VEVENT",
        f"UID:{uid}",
        "DTSTAMP:" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        f"SUMMARY:{esc(summary)}",
        "DTSTART" + _fmt_dt(start, all_day),
        "DTEND" + _fmt_dt(end, all_day),
    ]
    if platform:
        lines.append("CATEGORIES:" + esc(platform))
    if b.get("location"):
        lines.append(f"LOCATION:{esc(b['location'])}")
    # Description names the EXACT source email (from / subject / date) so it can be
    # found by local search, plus a Proton Mail link. Proton exposes no per-message
    # URL over hydroxide, so the link opens the mailbox, not the single message.
    desc = []
    if b.get("confirmation_code"):
        desc.append("Ref: " + b["confirmation_code"])
    if b.get("notes"):
        desc.append(b["notes"])
    src_from = b.get("_source_from")
    src_subject = b.get("_source_subject")
    src_date = b.get("_source_date")
    src_link = b.get("_source_link")
    if src_subject or src_from:
        meta = ", ".join(p for p in [
            f"from {src_from}" if src_from else "",
            f"on {src_date}" if src_date else "",
        ] if p)
        desc.append(f'Email: "{src_subject or ""}"' + (f" ({meta})" if meta else ""))
    if src_link:
        desc.append(src_link)
    desc.append("added by travel-cal-sync")
    lines.append("DESCRIPTION:" + esc(" — ".join(desc)))
    if src_link:  # clickable link on the event in Nextcloud
        lines.append("URL:" + src_link)
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return "\r\n".join(_fold(ln) for ln in lines) + "\r\n"


def _nc_auth():
    tok = base64.b64encode(f"{NC_USER}:{read_file(NC_PASS_FILE)}".encode()).decode()
    return "Basic " + tok


def caldav_put(uid, ics):
    if not NC_CAL:
        raise RuntimeError("NEXTCLOUD_CAL is not set — cannot write events")
    url = f"{CALDAV_HOME}{NC_CAL}/{uid}.ics"
    req = urllib.request.Request(
        url, data=ics.encode(),
        headers={"Authorization": _nc_auth(), "Content-Type": "text/calendar; charset=utf-8"},
        method="PUT",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status  # 201 created / 204 updated


def list_calendars():
    body = (
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:">'
        "<d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>"
    )
    req = urllib.request.Request(
        CALDAV_HOME, data=body.encode(),
        headers={"Authorization": _nc_auth(), "Depth": "1", "Content-Type": "application/xml"},
        method="PROPFIND",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        xml = r.read().decode("utf-8", "replace")
    out = []
    for resp in re.findall(r"(?is)<d:response>.*?</d:response>", xml):
        href = re.search(r"(?is)<d:href>(.*?)</d:href>", resp)
        name = re.search(r"(?is)<d:displayname>(.*?)</d:displayname>", resp)
        if not href:
            continue
        uri = href.group(1).rstrip("/").rsplit("/", 1)[-1]
        if uri and "calendar" in resp.lower():
            out.append((uri, html.unescape(name.group(1)) if name else ""))
    return out


# ── telegram ────────────────────────────────────────────────────────────────
def telegram(msg):
    if not TG_CHAT or not os.path.exists(TG_TOKEN_FILE):
        return
    try:
        tok = read_file(TG_TOKEN_FILE)
        data = urllib.parse.urlencode({
            "chat_id": TG_CHAT, "parse_mode": "HTML", "text": msg,
        }).encode()
        urllib.request.urlopen(
            f"https://api.telegram.org/bot{tok}/sendMessage", data=data, timeout=15
        )
    except Exception as e:  # noqa: BLE001 — never let a notify failure kill the run
        log("telegram error:", e)


# ── scan ────────────────────────────────────────────────────────────────────
def scan(M, state, dry_run):
    """One pass. Returns list of (booking, uid, written_bool)."""
    since_epoch = state["last_scan"]
    if since_epoch:
        since = datetime.fromtimestamp(since_epoch, timezone.utc) - timedelta(days=2)
    else:
        since = datetime.now(timezone.utc) - timedelta(days=LOOKBACK_DAYS)
    typ, ids = M.search(None, "SINCE", since.strftime("%d-%b-%Y"))
    if typ != "OK":
        raise RuntimeError("IMAP SEARCH failed")
    nums = ids[0].split()
    heads = fetch_headers(M, nums)
    log(f"scan: {len(nums)} message(s) since {since:%Y-%m-%d}; screening headers")
    seen = set(state["seen"])
    results = []
    done_uids = set()  # collapse multiple emails of the same booking within a scan
    for num in nums:
        head = heads.get(num.decode())
        if head is None:
            continue
        mid = (head.get("Message-ID") or "").strip()
        if mid and mid in seen:
            continue
        frm = decode_header(head.get("From"))
        subj = decode_header(head.get("Subject"))
        # Drop "queries" (inquiries / pending requests / searches) up front, and
        # non-candidates. Both are marked seen so they aren't reprocessed.
        if NEGATIVE_SUBJECT_RE.search(subj or "") or not is_candidate(frm, subj):
            if mid:
                seen.add(mid); state["seen"].append(mid)
            continue
        # full fetch only for candidates
        typ, d = M.fetch(num, "(BODY.PEEK[])")
        if typ != "OK" or not d or not d[0]:
            continue
        msg = email.message_from_bytes(d[0][1])
        text = f"From: {frm}\nSubject: {subj}\n\n{body_text(msg)}"
        # Received date, used to roll year-less trip dates forward (below). Only
        # trust it for recently-arrived mail so we never promote a genuine old trip.
        try:
            recv_date = email.utils.parsedate_to_datetime(msg.get("Date")).date()
        except Exception:  # noqa: BLE001
            recv_date = None
        recent = bool(recv_date and recv_date >= datetime.now(timezone.utc).date() - timedelta(days=60))
        try:
            bookings = extract_booking(text)
        except UpstreamDown:
            # Model host (beast) is down — stop the scan and let the daemon back
            # off. This message stays unseen, so it's retried once beast is up.
            raise
        except Exception as e:  # noqa: BLE001
            log("extract error:", e, "— subject:", subj)
            continue
        cutoff = datetime.now(timezone.utc).date() - timedelta(days=PAST_GRACE_DAYS)
        write_failed = False
        for b in bookings:
            if (not isinstance(b, dict) or not b.get("is_booking")
                    or not b.get("start") or b.get("type") not in TRAVEL_TYPES):
                continue
            if recent:
                roll_year_forward(b, recv_date)  # fix a dropped/mis-guessed year
            # Drop trips that already ended (use end date, else start).
            ref = (b.get("end") or b.get("start") or "")[:10]
            try:
                ref_date = datetime.fromisoformat(ref).date()
            except ValueError:
                continue
            if ref_date < cutoff:
                continue
            # Source-email breadcrumbs for the event description / URL.
            b["_source_from"] = frm
            b["_source_subject"] = subj
            b["_source_date"] = recv_date.isoformat() if recv_date else None
            b["_source_link"] = PROTON_MAIL_URL
            b["_platform"] = source_platform(frm)
            uid = booking_uid(b)
            if uid in done_uids:
                continue
            # Build first: a malformed booking (bad datetime) is a PERMANENT skip —
            # dedupe it so it isn't retried, and don't set write_failed (the source
            # message can still be marked seen). Only a CalDAV PUT failure is
            # transient → write_failed → message left unseen for retry.
            try:
                ics = build_ics(b, uid)
            except Exception as e:  # noqa: BLE001
                log("skip malformed booking:", e, "—", b.get("title"))
                done_uids.add(uid)
                continue
            written = False
            if not dry_run:
                try:
                    caldav_put(uid, ics)
                    written = True
                except Exception as e:  # noqa: BLE001
                    log("caldav error:", e, "— booking:", b.get("title"))
                    write_failed = True
            # Dedupe a UID once safely written (or in dry-run); a failed write is
            # left un-deduped so a later email for it can still succeed this scan.
            if written or dry_run:
                done_uids.add(uid)
            results.append((b, uid, written))
        # Mark the source message processed ONLY if nothing failed to write, so a
        # transient CalDAV outage doesn't permanently drop a booking — the message
        # stays unseen and is retried on the next scan.
        if mid and not write_failed:
            seen.add(mid); state["seen"].append(mid)
    state["last_scan"] = int(time.time())
    return results


def fmt_booking(b):
    span = b.get("start", "")
    if b.get("end"):
        span += " → " + b["end"]
    loc = f" @ {b['location']}" if b.get("location") else ""
    code = f" [{b['confirmation_code']}]" if b.get("confirmation_code") else ""
    return f"{b.get('type', '?'):5} {span}  {b.get('title', '')}{loc}{code}"


def event_link(b):
    """Deep link into the Nextcloud Calendar app at the trip's start date (month
    view), so the Telegram message links straight to the appointment."""
    date = (b.get("start") or "")[:10] or "now"
    return f"{NC_WEB}/apps/calendar/dayGridMonth/{date}"


# ── IDLE ────────────────────────────────────────────────────────────────────
def idle_wait(M, timeout):
    """Block until new mail (EXISTS/RECENT) or timeout. Returns True if woken."""
    tag = M._new_tag()
    M.send(tag + b" IDLE\r\n")
    if not M.readline().startswith(b"+"):
        raise RuntimeError("server did not enter IDLE")
    woken = False
    M.socket().settimeout(timeout)
    try:
        while True:
            line = M.readline()
            if not line:
                break
            if b"EXISTS" in line or b"RECENT" in line:
                woken = True
                break
    except socket.timeout:
        pass
    finally:
        # Finite (NOT None): a black-holed connection must not wedge the drain
        # forever. A timeout here raises and the daemon's reconnect loop handles it.
        M.socket().settimeout(IDLE_DRAIN_TIMEOUT)
        M.send(b"DONE\r\n")
        while True:  # drain to the tagged completion
            line = M.readline()
            if not line or line.startswith(tag):
                break
        M.socket().settimeout(SOCKET_TIMEOUT)  # restore for subsequent commands
    return woken


# ── modes ───────────────────────────────────────────────────────────────────
def run_dry_run():
    # Fresh state (NOT the daemon's persisted state): re-evaluate the entire
    # LOOKBACK window so the review list is complete, regardless of what the
    # running daemon has already marked seen.
    state = {"seen": [], "last_scan": 0}
    M = imap_connect()
    try:
        results = scan(M, state, dry_run=True)
    except UpstreamDown as e:
        log(f"cannot extract — LLM upstream down ({e}). Is beast awake?")
        return 2
    finally:
        try:
            M.logout()
        except Exception:  # noqa: BLE001
            pass
    print(f"\n=== {len(results)} travel booking(s) detected "
          f"(last {LOOKBACK_DAYS} days) ===")
    for b, uid, _ in results:
        print("  " + fmt_booking(b))
    print("\n(dry-run — nothing was written to the calendar)")
    return 0


def run_list_calendars():
    for uri, name in list_calendars():
        print(f"{uri}\t{name}")
    return 0


def run_daemon():
    log("travel-cal-sync daemon starting")
    M = None
    while True:
        try:
            M = imap_connect()
            log("connected; running catch-up scan")
            while True:
                state = load_state()
                try:
                    results = scan(M, state, dry_run=False)
                except UpstreamDown as e:
                    save_state(state)  # keep partial progress
                    log(f"LLM upstream down ({e}); backing off 15 min")
                    time.sleep(900)
                    continue
                save_state(state)
                new = [r for r in results if r[2]]
                if new:
                    log(f"added {len(new)} event(s)")
                    lines = [
                        f'• {html.escape(fmt_booking(b))}\n'
                        f'  <a href="{event_link(b)}">📅 Open in calendar</a>'
                        for b, _, _ in new
                    ]
                    telegram("🧳 <b>Travel bookings added to calendar</b>\n" + "\n".join(lines))
                # trigger: block on IDLE until new mail or the safety-net timeout
                idle_wait(M, RESCAN_SECONDS)
        except Exception as e:  # noqa: BLE001
            log("daemon error, reconnecting in 30s:", type(e).__name__, e)
            try:
                if M is not None:
                    M.logout()
            except Exception:  # noqa: BLE001
                pass
            M = None
            time.sleep(30)


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--dry-run":
        return run_dry_run()
    if arg == "--list-calendars":
        return run_list_calendars()
    return run_daemon()


if __name__ == "__main__":
    sys.exit(main())
