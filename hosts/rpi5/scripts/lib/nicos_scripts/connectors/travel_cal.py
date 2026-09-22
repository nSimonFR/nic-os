#!/usr/bin/env python3
"""travel-cal-sync — event-driven Proton → Nextcloud travel-booking calendar sync.

Reads Proton over the local hydroxide IMAP bridge (same creds/pattern as
`nicos_scripts.papra.proton_poll`), detects travel bookings (Airbnb / hotels /
flights / trains) with the local `tiny-llm-gate`, and writes each as a VEVENT into
a Nextcloud calendar over CalDAV. Each booking gets a stable UID, so the PUT is
idempotent — re-runs update in place and never create duplicates, even if the
state file is lost.

With PAPRA_DEST set it also files document attachments into Papra's ingestion
folder: a confirmed upcoming booking's tickets/vouchers, named from the trip;
and (PAPRA_FILE_ALL_MAIL=1) any other mail carrying a document, after a second
LLM call judges it worth archiving. Candidates come from BODYSTRUCTURE in the
batched header fetch, so most mail costs no body fetch and no LLM call. Mail
papra-proton-poll already filed (its Message-ID ledger) is skipped.

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
  TELEGRAM_SEND         the one-shot Telegram seam (shared/notify.nix `send`);
                        no summary if unset
  PAPRA_DEST            Papra ingestion dir <root>/<orgId>; unset = no filing
  PAPRA_POLL_STATE      default /var/lib/papra-proton-poll/seen
  PAPRA_FILE_ALL_MAIL   default 1; 0 = travel documents only
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
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from ..logs import logger
from ..papra import proton_poll
from ..secrets import env_int, env_str, read_secret
from ..state import ensure_dir, load_json, save_json

# Logging goes to stderr here (unlike the other units): stdout is the --dry-run
# report, which is meant to be read or piped.
log = logger("travel-cal-sync", stream=lambda: sys.stderr)

IMAP_HOST = "127.0.0.1"
IMAP_PORT = 1143

DEFAULT_PROTON_USER = "nsimon@protonmail.com"
DEFAULT_PROTON_PASS_FILE = "/run/agenix/protonmail-bridge-password"
DEFAULT_MAILBOX = "All Mail"
DEFAULT_GATE = "http://127.0.0.1:4001"
DEFAULT_MODEL = "auto"
DEFAULT_LOOKBACK_DAYS = 365
DEFAULT_STATE_DIR = "/var/lib/travel-cal-sync"
DEFAULT_RESCAN_SECONDS = 1200
DEFAULT_CALDAV_HOME = (
    "https://rpi5.gate-mintaka.ts.net/nextcloud/remote.php/dav/calendars/nsimon/"
)
DEFAULT_NC_PASS_FILE = "/run/agenix/travel-cal-nextcloud-password"
DEFAULT_PAPRA_POLL_STATE = "/var/lib/papra-proton-poll/seen"

# Socket timeout for normal IMAP commands, so a black-holed connection surfaces
# as an error the reconnect loop can handle instead of blocking forever.
SOCKET_TIMEOUT = 300
IDLE_DRAIN_TIMEOUT = 60  # finite timeout for the IDLE DONE-drain

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

# Keep the seen-set bounded but comfortably larger than any plausible
# rescan-window (SINCE last_scan-2d) message count, so an in-window Message-ID
# is never evicted and reprocessed. (Re-processing is idempotent anyway via
# the stable UID, but this avoids wasted LLM/CalDAV calls.)
SEEN_CAP = 20000


@dataclass(frozen=True)
class Config:
    proton_user: str = DEFAULT_PROTON_USER
    proton_pass_file: str = DEFAULT_PROTON_PASS_FILE
    mailbox: str = DEFAULT_MAILBOX
    gate: str = DEFAULT_GATE
    model: str = DEFAULT_MODEL
    lookback_days: int = DEFAULT_LOOKBACK_DAYS
    state_dir: str = DEFAULT_STATE_DIR
    rescan_seconds: int = DEFAULT_RESCAN_SECONDS
    caldav_home: str = DEFAULT_CALDAV_HOME
    nc_user: str = "nsimon"
    nc_pass_file: str = DEFAULT_NC_PASS_FILE
    nc_cal: str = ""
    # The one-shot seam (shared/notify.nix `send`), already carrying the bot-token
    # path and chat id. See telegram() below.
    telegram_send: str = ""
    imap_host: str = IMAP_HOST
    imap_port: int = IMAP_PORT
    papra_dest: str = ""
    papra_poll_state: str = DEFAULT_PAPRA_POLL_STATE
    file_all_mail: bool = True

    @classmethod
    def from_env(cls, env=None):
        return cls(
            proton_user=env_str("PROTON_USER", DEFAULT_PROTON_USER, env),
            proton_pass_file=env_str("PROTON_PASS_FILE", DEFAULT_PROTON_PASS_FILE, env),
            mailbox=env_str("PROTON_MAILBOX", DEFAULT_MAILBOX, env),
            gate=env_str("TINY_LLM_GATE_URL", DEFAULT_GATE, env).rstrip("/"),
            model=env_str("MODEL", DEFAULT_MODEL, env),
            lookback_days=env_int("LOOKBACK_DAYS", DEFAULT_LOOKBACK_DAYS, env),
            state_dir=env_str("STATE_DIR", DEFAULT_STATE_DIR, env),
            rescan_seconds=env_int("RESCAN_SECONDS", DEFAULT_RESCAN_SECONDS, env),
            caldav_home=env_str("NEXTCLOUD_CALDAV_URL", DEFAULT_CALDAV_HOME, env).rstrip("/") + "/",
            nc_user=env_str("NEXTCLOUD_USER", "nsimon", env),
            nc_pass_file=env_str("NEXTCLOUD_PASS_FILE", DEFAULT_NC_PASS_FILE, env),
            nc_cal=env_str("NEXTCLOUD_CAL", "", env),
            telegram_send=env_str("TELEGRAM_SEND", "", env),
            papra_dest=env_str("PAPRA_DEST", "", env),
            papra_poll_state=env_str("PAPRA_POLL_STATE", DEFAULT_PAPRA_POLL_STATE, env),
            file_all_mail=env_str("PAPRA_FILE_ALL_MAIL", "1", env) not in ("0", "", "false"),
        )

    @property
    def state_file(self):
        return os.path.join(self.state_dir, "state.json")

    @property
    def nc_web(self):
        """Nextcloud web base (for calendar deep links), derived from the CalDAV URL:
        https://host/nextcloud/remote.php/dav/... -> https://host/nextcloud"""
        return self.caldav_home.split("/remote.php")[0]


# ── small utils ─────────────────────────────────────────────────────────────

def source_platform(frm):
    frm = (frm or "").lower()
    for sub, label in SOURCE_PLATFORMS:
        if sub in frm:
            return label
    return ""


def decode_header(s):
    """Decode an RFC 2047 header (=?utf-8?...?=) so encoded subjects match the
    candidate regex and reach the model as real text, not mojibake."""
    if not s:
        return ""
    try:
        return str(email.header.make_header(email.header.decode_header(s)))
    except Exception:  # noqa: BLE001
        return s


def load_state(cfg):
    s = load_json(cfg.state_file, {})
    if not isinstance(s, dict):
        s = {}
    s.setdefault("seen", [])       # processed Message-IDs
    s.setdefault("last_scan", 0)   # epoch of last successful scan
    return s


def save_state(cfg, s):
    ensure_dir(cfg.state_dir)
    s["seen"] = s["seen"][-SEEN_CAP:]
    save_json(cfg.state_file, s)


# ── IMAP ────────────────────────────────────────────────────────────────────

def imap_connect(cfg):
    M = imaplib.IMAP4(cfg.imap_host, cfg.imap_port)
    M.socket().settimeout(SOCKET_TIMEOUT)  # login/select/search/fetch can't hang forever
    M.login(cfg.proton_user, read_secret(cfg.proton_pass_file))
    mbox = f'"{cfg.mailbox}"' if " " in cfg.mailbox else cfg.mailbox
    typ, _ = M.select(mbox, readonly=True)
    if typ != "OK":
        raise RuntimeError(f"cannot select mailbox {cfg.mailbox!r}")
    return M


def fetch_headers(M, ids, chunk=500):
    """Batch-fetch minimal headers + BODYSTRUCTURE for all message numbers
    → ({num: email.Message}, {num: bodystructure}). One IMAP round-trip per
    `chunk` messages; BODYSTRUCTURE rides in the FETCH prelude for free."""
    out, structs = {}, {}
    for i in range(0, len(ids), chunk):
        batch = b",".join(ids[i:i + chunk])
        typ, data = M.fetch(
            batch, "(BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT MESSAGE-ID)])")
        if typ != "OK":
            continue
        for item in data:
            if not isinstance(item, tuple):
                continue
            m = re.match(rb"(\d+)", item[0])
            if m:
                num = m.group(1).decode()
                out[num] = email.message_from_bytes(item[1])
                structs[num] = item[0].decode("utf-8", "replace")
    return out, structs


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
    """The LLM gate or its model is unavailable (host down, plan quota hit). Signals the
    daemon to back off rather than hammer every candidate."""


def llm_json(cfg, system_prompt, text, opener=None):
    """One temperature-0 completion parsed as JSON (None if unparseable). Raises
    UpstreamDown when the gate or its model is unavailable, so callers back off."""
    body = json.dumps({
        "model": cfg.model,
        "temperature": 0,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": text},
        ],
    }).encode()
    req = urllib.request.Request(
        f"{cfg.gate}/v1/chat/completions",
        data=body,
        headers={"Authorization": "Bearer ollama", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with (opener or urllib.request.urlopen)(req, timeout=120) as r:
            content = json.load(r)["choices"][0]["message"]["content"]
    except urllib.error.HTTPError as e:
        # 502/503/504 = gate reached but the model upstream is down; 429 = the
        # ChatGPT plan's usage limit, which resets hours later.
        if e.code in (429, 502, 503, 504):
            raise UpstreamDown(f"gate {e.code}") from e
        raise
    except urllib.error.URLError as e:
        raise UpstreamDown(f"gate unreachable: {e.reason}") from e
    except (TimeoutError, socket.timeout) as e:
        # Slow/asleep model host — treat like upstream-down so the daemon backs
        # off instead of skipping this message as a one-off extract error.
        raise UpstreamDown(f"gate timeout: {e}") from e
    return _parse_json(content)


def extract_booking(cfg, text, opener=None):
    return normalise_bookings(llm_json(cfg, SYSTEM_PROMPT, text, opener))


def normalise_bookings(data):
    """Normalise to a list of booking dicts: an email may hold several legs (a
    round-trip = two flights), so the model may return an array — or wrap the
    array under a key."""
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


def build_ics(b, uid, now=None):
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
    stamp = (now or datetime.now(timezone.utc)).strftime("%Y%m%dT%H%M%SZ")
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//nic-os//travel-cal-sync//EN",
        "BEGIN:VEVENT",
        f"UID:{uid}",
        "DTSTAMP:" + stamp,
        f"SUMMARY:{esc(summary)}",
        "DTSTART" + _fmt_dt(start, all_day),
        "DTEND" + _fmt_dt(end, all_day),
    ]
    if platform:
        lines.append("CATEGORIES:" + esc(platform))
    if b.get("location"):
        lines.append(f"LOCATION:{esc(b['location'])}")
    # Description names the EXACT source email (from / subject / date) so it can be
    # found by Proton's (client-side) local search. No mailbox link — Proton exposes
    # no per-message URL over hydroxide, and a link that only opens the mailbox is
    # not useful, so it's omitted.
    desc = []
    if b.get("confirmation_code"):
        desc.append("Ref: " + b["confirmation_code"])
    if b.get("notes"):
        desc.append(b["notes"])
    src_from = b.get("_source_from")
    src_subject = b.get("_source_subject")
    src_date = b.get("_source_date")
    if src_subject or src_from:
        meta = ", ".join(p for p in [
            f"from {src_from}" if src_from else "",
            f"on {src_date}" if src_date else "",
        ] if p)
        desc.append(f'Email: "{src_subject or ""}"' + (f" ({meta})" if meta else ""))
    desc.append("added by travel-cal-sync")
    lines.append("DESCRIPTION:" + esc(" — ".join(desc)))
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return "\r\n".join(_fold(ln) for ln in lines) + "\r\n"


def _nc_auth(cfg):
    tok = base64.b64encode(
        f"{cfg.nc_user}:{read_secret(cfg.nc_pass_file)}".encode()).decode()
    return "Basic " + tok


def caldav_put(cfg, uid, ics, opener=None):
    if not cfg.nc_cal:
        raise RuntimeError("NEXTCLOUD_CAL is not set — cannot write events")
    url = f"{cfg.caldav_home}{cfg.nc_cal}/{uid}.ics"
    req = urllib.request.Request(
        url, data=ics.encode(),
        headers={"Authorization": _nc_auth(cfg),
                 "Content-Type": "text/calendar; charset=utf-8"},
        method="PUT",
    )
    with (opener or urllib.request.urlopen)(req, timeout=30) as r:
        return r.status  # 201 created / 204 updated


def list_calendars(cfg, opener=None):
    body = (
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:">'
        "<d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>"
    )
    req = urllib.request.Request(
        cfg.caldav_home, data=body.encode(),
        headers={"Authorization": _nc_auth(cfg), "Depth": "1",
                 "Content-Type": "application/xml"},
        method="PROPFIND",
    )
    with (opener or urllib.request.urlopen)(req, timeout=30) as r:
        xml = r.read().decode("utf-8", "replace")
    return parse_calendar_list(xml)


def parse_calendar_list(xml):
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
def telegram(cfg, msg, run=None):
    """Post a one-shot booking summary through the shared sender.

    Not hand-rolled here: cfg.telegram_send points at the one-shot seam
    (shared/notify.nix `send`), which owns parse mode, urlencoding, timeouts and
    best-effort failure for every one-shot sender. Unset → no-op.
    """
    if not cfg.telegram_send:
        return
    try:
        (run or subprocess.run)(
            [cfg.telegram_send, msg], stdout=subprocess.DEVNULL, timeout=30, check=False
        )
    except Exception as e:  # noqa: BLE001 — never let a notify failure kill the run
        log(f"telegram error: {e}")


# ── Papra document filing ───────────────────────────────────────────────────

DOC_SYSTEM_PROMPT = (
    "You decide whether an email's attachment is a personal document worth "
    "archiving in a document manager. Reply with ONLY a JSON object, no prose, "
    "no markdown fences. Schema:\n"
    "{\n"
    '  "archive": bool,     // true only for a real document worth keeping\n'
    '  "issuer": str,       // short name of the issuing organisation, e.g.\n'
    '                       // "URSSAF", "AXA", "Storj", "IKEA"; "" if unclear\n'
    '  "doc_date": str,     // the document\'s OWN date, YYYY-MM-DD; "" if absent\n'
    '  "kind": str          // short type, e.g. "facture", "fiche de paie"\n'
    "}\n"
    "ARCHIVE=true for: invoices, bills, receipts, order confirmations with an "
    "invoice, bank/card statements, payslips, tax documents, contracts, quotes, "
    "insurance policies and claims, official letters from government or "
    "administration, medical documents and test results, certificates and "
    "attestations, warranties, delivery notes, tickets.\n"
    "ARCHIVE=false for: marketing and promotional PDFs, newsletters, catalogues, "
    "brochures, product advertising, event flyers, sales decks, terms-and-"
    "conditions attached to marketing mail, email signatures, logos and other "
    "decorative images. When the attachment is merely advertising, return false "
    "even if the email looks official."
)


def judge_document(cfg, text, opener=None):
    data = llm_json(cfg, DOC_SYSTEM_PROMPT, text, opener)
    return data if isinstance(data, dict) else None


# Only decides whether a body fetch is worth it; proton_poll.is_doc on the real
# parts stays the authoritative triage, so a loose match just wastes one fetch.
_IMG_SIZE_RE = re.compile(r'"IMAGE"\s+"[^"]*"(?:[^()]|\([^()]*\))*?\s(\d{5,})', re.I)


def maybe_has_doc(bodystructure):
    """PDFs always; images only above the size floor, so logos don't trigger."""
    if not bodystructure:
        return False
    if "PDF" in bodystructure.upper():
        return True
    return any(int(m) >= proton_poll.MIN_IMG_BYTES
               for m in _IMG_SIZE_RE.findall(bodystructure))


def _prefixed(fn, *parts):
    prefix = " ".join(p for p in parts if p)
    return f"{prefix} - {fn}" if prefix else fn


def trip_doc_name(fn, b):
    """`2026-08-03 SNCF Connect - ticket.pdf` from an opaque `ticket.pdf`."""
    return _prefixed(fn, (b.get("start") or "")[:10], b.get("_platform") or "")


def judged_doc_name(fn, judged, recv_date):
    """`<doc date> <issuer> - <original>`, the received date when none is stated."""
    date = (judged.get("doc_date") or "")[:10]
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", date):
        date = recv_date.isoformat() if recv_date else ""
    return _prefixed(fn, date, (judged.get("issuer") or "").strip())


def file_documents(cfg, msg, namer, dry_run, chown=proton_poll.chown_papra):
    """Drop the message's document attachments into Papra. -> filed names."""
    filed = []
    for ct, fn, _disp, payload in proton_poll.attachments(msg):
        name = proton_poll.safe(namer(decode_header(fn) or "attachment"))
        if dry_run:
            filed.append(f"{name} ({ct}, {len(payload)}B)")
            continue
        dest = proton_poll.save_attachment(cfg.papra_dest, payload, name, chown=chown)
        filed.append(os.path.basename(dest))
        log(f"papra: filed {os.path.basename(dest)} ({ct}, {len(payload)}B)")
    return filed


# ── scan ────────────────────────────────────────────────────────────────────

def scan(cfg, M, state, dry_run, extract=None, put=None, now=None,
         judge=None, filed=None, chown=proton_poll.chown_papra):
    """One pass. Returns list of (booking, uid, written_bool); Papra filenames are
    appended to `filed` when given."""
    extract = extract or (lambda text: extract_booking(cfg, text))
    judge = judge or (lambda text: judge_document(cfg, text))
    put = put or (lambda uid, ics: caldav_put(cfg, uid, ics))
    now = now or datetime.now(timezone.utc)
    filed = [] if filed is None else filed

    since_epoch = state["last_scan"]
    if since_epoch:
        since = datetime.fromtimestamp(since_epoch, timezone.utc) - timedelta(days=2)
    else:
        since = now - timedelta(days=cfg.lookback_days)
    typ, ids = M.search(None, "SINCE", since.strftime("%d-%b-%Y"))
    if typ != "OK":
        raise RuntimeError("IMAP SEARCH failed")
    nums = ids[0].split()
    heads, structs = fetch_headers(M, nums)
    log(f"scan: {len(nums)} message(s) since {since:%Y-%m-%d}; screening headers")
    seen = set(state["seen"])
    results = []
    done_uids = set()  # collapse multiple emails of the same booking within a scan
    papra_seen = proton_poll.load_seen(cfg.papra_poll_state) if cfg.papra_dest else set()
    for num in nums:
        head = heads.get(num.decode())
        if head is None:
            continue
        mid = (head.get("Message-ID") or "").strip()
        if mid and mid in seen:
            continue
        frm = decode_header(head.get("From"))
        subj = decode_header(head.get("Subject"))
        # "Queries" (inquiries / pending requests / searches) are never bookings.
        is_travel = bool(not NEGATIVE_SUBJECT_RE.search(subj or "")
                         and is_candidate(frm, subj))
        may_file = bool(cfg.papra_dest and mid not in papra_seen)
        has_doc = may_file and maybe_has_doc(structs.get(num.decode()))
        # Nothing to do → marked seen so it isn't reprocessed.
        if not is_travel and not (cfg.file_all_mail and has_doc):
            if mid:
                seen.add(mid)
                state["seen"].append(mid)
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
        recent = bool(recv_date and recv_date >= now.date() - timedelta(days=60))
        bookings = []
        if is_travel:  # a payslip must never go through the trip parser
            try:
                bookings = extract(text)
            except UpstreamDown:
                # Model upstream unavailable — stop the scan and let the daemon
                # back off. This message stays unseen, so it's retried later.
                raise
            except Exception as e:  # noqa: BLE001
                log(f"extract error: {e} — subject: {subj}")
                continue
        cutoff = now.date() - timedelta(days=PAST_GRACE_DAYS)
        write_failed = False
        # Naming context for the attachments, taken BEFORE the per-UID dedupe so a
        # reminder whose event already exists still files its boarding pass.
        doc_booking = None
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
            b["_platform"] = source_platform(frm)
            if doc_booking is None:
                doc_booking = b
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
                log(f"skip malformed booking: {e} — {b.get('title')}")
                done_uids.add(uid)
                continue
            written = False
            if not dry_run:
                try:
                    put(uid, ics)
                    written = True
                except Exception as e:  # noqa: BLE001
                    log(f"caldav error: {e} — booking: {b.get('title')}")
                    write_failed = True
            # Dedupe a UID once safely written (or in dry-run); a failed write is
            # left un-deduped so a later email for it can still succeed this scan.
            if written or dry_run:
                done_uids.add(uid)
            results.append((b, uid, written))
        # A filing failure is logged but never sets write_failed: the dest is a
        # local dir, and retrying would re-run the LLM on every scan.
        try:
            if doc_booking is not None and may_file:
                filed += file_documents(
                    cfg, msg, lambda fn: trip_doc_name(fn, doc_booking), dry_run, chown)
            elif has_doc and cfg.file_all_mail:
                judged = judge(text)
                if judged and judged.get("archive"):
                    filed += file_documents(
                        cfg, msg, lambda fn: judged_doc_name(fn, judged, recv_date),
                        dry_run, chown)
                elif judged:
                    log(f"papra: not archiving {subj!r} (kind={judged.get('kind') or '?'})")
        except UpstreamDown:
            raise
        except Exception as e:  # noqa: BLE001
            log(f"papra filing error: {e} — subject: {subj}")
        # Mark the source message processed ONLY if nothing failed to write, so a
        # transient CalDAV outage doesn't permanently drop a booking — the message
        # stays unseen and is retried on the next scan.
        if mid and not write_failed:
            seen.add(mid)
            state["seen"].append(mid)
    state["last_scan"] = int(time.time())
    return results


def fmt_booking(b):
    span = b.get("start", "")
    if b.get("end"):
        span += " → " + b["end"]
    loc = f" @ {b['location']}" if b.get("location") else ""
    code = f" [{b['confirmation_code']}]" if b.get("confirmation_code") else ""
    return f"{b.get('type', '?'):5} {span}  {b.get('title', '')}{loc}{code}"


def event_link(cfg, b):
    """Deep link into the Nextcloud Calendar app at the trip's start date (month
    view), so the Telegram message links straight to the appointment."""
    date = (b.get("start") or "")[:10] or "now"
    return f"{cfg.nc_web}/apps/calendar/dayGridMonth/{date}"


def telegram_summary(cfg, new, filed=()):
    parts = []
    if new:
        parts.append("🧳 <b>Travel bookings added to calendar</b>\n" + "\n".join(
            f'• {html.escape(fmt_booking(b))}\n'
            f'  <a href="{event_link(cfg, b)}">📅 Open in calendar</a>'
            for b, _, _ in new))
    if filed:
        parts.append("📄 <b>Filed to Papra</b>\n" + "\n".join(
            f"• {html.escape(n)}" for n in filed))
    return "\n\n".join(parts)


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

def run_dry_run(cfg, connect=None):
    # Fresh state (NOT the daemon's persisted state): re-evaluate the entire
    # LOOKBACK window so the review list is complete, regardless of what the
    # running daemon has already marked seen.
    state = {"seen": [], "last_scan": 0}
    M = (connect or imap_connect)(cfg)
    filed = []
    try:
        results = scan(cfg, M, state, dry_run=True, filed=filed)
    except UpstreamDown as e:
        log(f"cannot extract — LLM upstream down ({e})")
        return 2
    finally:
        try:
            M.logout()
        except Exception:  # noqa: BLE001
            pass
    print(f"\n=== {len(results)} travel booking(s) detected "
          f"(last {cfg.lookback_days} days) ===")
    for b, uid, _ in results:
        print("  " + fmt_booking(b))
    if cfg.papra_dest:
        print(f"\n=== {len(filed)} document(s) would be filed to Papra ===")
        for name in filed:
            print("  " + name)
    print("\n(dry-run — nothing was written to the calendar or to Papra)")
    return 0


def run_list_calendars(cfg):
    for uri, name in list_calendars(cfg):
        print(f"{uri}\t{name}")
    return 0


def run_daemon(cfg, connect=None, sleep=time.sleep, once=False):
    log("travel-cal-sync daemon starting")
    M = None
    while True:
        try:
            M = (connect or imap_connect)(cfg)
            log("connected; running catch-up scan")
            while True:
                state = load_state(cfg)
                filed = []
                try:
                    results = scan(cfg, M, state, dry_run=False, filed=filed)
                except UpstreamDown as e:
                    save_state(cfg, state)  # keep partial progress
                    log(f"LLM upstream down ({e}); backing off 15 min")
                    sleep(900)
                    if once:
                        return 0
                    continue
                save_state(cfg, state)
                new = [r for r in results if r[2]]
                if new or filed:
                    log(f"added {len(new)} event(s), filed {len(filed)} document(s)")
                    telegram(cfg, telegram_summary(cfg, new, filed))
                if once:
                    return 0
                # trigger: block on IDLE until new mail or the safety-net timeout
                idle_wait(M, cfg.rescan_seconds)
        except Exception as e:  # noqa: BLE001
            log(f"daemon error, reconnecting in 30s: {type(e).__name__} {e}")
            try:
                if M is not None:
                    M.logout()
            except Exception:  # noqa: BLE001
                pass
            M = None
            if once:
                return 1
            sleep(30)


def main(argv=None, env=None):
    cfg = Config.from_env(env)
    argv = sys.argv[1:] if argv is None else argv
    arg = argv[0] if argv else ""
    if arg == "--dry-run":
        return run_dry_run(cfg)
    if arg == "--list-calendars":
        return run_list_calendars(cfg)
    return run_daemon(cfg)


if __name__ == "__main__":
    sys.exit(main())
