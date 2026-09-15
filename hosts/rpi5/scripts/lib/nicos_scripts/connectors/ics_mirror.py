#!/usr/bin/env python3
"""ics-mirror — fetch remote ICS feeds, window them to a date range, serve them small.

Calino subscribes to webcal feeds from the BROWSER and persists every parsed event
into `calino-storage` in raw localStorage (~5 MB/origin). The TRUSK Google feed is
6234 VEVENTs / 9.8 MB, so subscribing to it directly overflows the quota and Calino
toasts "Storage is full. Your data may not be saved." — after which the store silently
fails to persist. See known_issue_calino_webcal_import_oom.

This mirror is the fix: a timer fetches each feed server-side, keeps only the
components that can render inside a -3/+12-month window, and writes a small .ics that
nginx serves from Calino's OWN origin (tailnet-only :3800, NOT on the public 443
funnel). Calino then subscribes same-origin — no CORS, and the `/gcal/` browser
passthrough this replaces is gone.

⚠ NO CONDITIONAL GET IS POSSIBLE. Google answers the private `basic.ics` with
  `cache-control: no-cache, no-store, must-revalidate` and sends NEITHER an ETag NOR
  a Last-Modified (measured 2026-09-15). So `If-None-Match` has nothing to send and
  every poll is a full transfer. Two consequences this file lives with:
    * `Accept-Encoding: gzip` is requested explicitly — urllib does not do it for you,
      and it is a 10x saving on this feed (1.0 MB on the wire vs 9.8 MB raw).
    * Freshness is decided by hashing the calendar ourselves — see `canonical_digest`.
      An unchanged digest means the file already on disk is the file we would write,
      so the write is skipped.

⚠ TWO THINGS THAT LOOK LIKE CHANGES AND ARE NOT. Both measured 2026-09-15 against
  this feed; either one alone makes a naive hash useless, and the failure is SILENT —
  the mirror keeps working, it just rewrites 370 kB every poll and reports a
  publishing cadence equal to the poll interval.
    * DTSTAMP is regenerated on every export. Two fetches seconds apart differ in all
      6235 of them and in nothing else.
    * COMPONENT ORDER is not stable. Those two fetches share a UID multiset but
      diverge at index 0.
  `canonical_digest` therefore drops DTSTAMP and sorts components before hashing, and
  `render` imposes its own order so the served file is deterministic too.

⚠ "Live" is bounded by Google, not by the poll interval. The private ICS feed is
  served from Google's own publishing cache and has historically lagged real edits by
  hours. `last_changed_at` in the state file records when the SEMANTIC digest moved,
  so the real lag can be measured rather than guessed.

Config via env:
  ICS_MIRROR_FEEDS_FILE  path to a JSON object {"<slug>": "<https url>", ...}
                         (agenix; the URLs carry unexpiring secret feed tokens, so
                         they must NEVER be committed to this PUBLIC repo)
  ICS_MIRROR_OUT_DIR     REQUIRED for writes; empty = refuse to write (safe default)
  ICS_MIRROR_STATE_DIR   default /var/lib/ics-mirror
  ICS_MIRROR_BACK_DAYS   default 92   (-3 months)
  ICS_MIRROR_FWD_DAYS    default 365  (+12 months)
  ICS_MIRROR_TIMEOUT     default 120  seconds

Flags:
  --dry-run   fetch + window + report the counts, write nothing.
"""

import datetime
import gzip
import hashlib
import json
import os
import re
import sys
import urllib.request
from dataclasses import dataclass

from ..logs import logger
from ..secrets import env_int, env_str
from ..state import ensure_dir, load_json, save_json

DEFAULT_STATE_DIR = "/var/lib/ics-mirror"
DEFAULT_BACK_DAYS = 92
DEFAULT_FWD_DAYS = 365
DEFAULT_TIMEOUT = 120

# Properties copied from the source VCALENDAR onto the windowed one. Anything else
# at the top level (Google emits none today) is dropped rather than guessed at.
HEADER_PROPS = (
    "PRODID",
    "VERSION",
    "CALSCALE",
    "METHOD",
    "X-WR-CALNAME",
    "X-WR-TIMEZONE",
    "X-WR-CALDESC",
)

log = logger("ics-mirror")


@dataclass(frozen=True)
class Config:
    # Empty out_dir is the SAFE default: a Config built from an empty env cannot
    # write anywhere (CLAUDE.md's rule for destructive defaults).
    out_dir: str = ""
    feeds_file: str = ""
    state_dir: str = DEFAULT_STATE_DIR
    back_days: int = DEFAULT_BACK_DAYS
    fwd_days: int = DEFAULT_FWD_DAYS
    timeout: int = DEFAULT_TIMEOUT

    @classmethod
    def from_env(cls, env=None):
        return cls(
            out_dir=env_str("ICS_MIRROR_OUT_DIR", "", env),
            feeds_file=env_str("ICS_MIRROR_FEEDS_FILE", "", env),
            state_dir=env_str("ICS_MIRROR_STATE_DIR", DEFAULT_STATE_DIR, env),
            back_days=env_int("ICS_MIRROR_BACK_DAYS", DEFAULT_BACK_DAYS, env),
            fwd_days=env_int("ICS_MIRROR_FWD_DAYS", DEFAULT_FWD_DAYS, env),
            timeout=env_int("ICS_MIRROR_TIMEOUT", DEFAULT_TIMEOUT, env),
        )

    @property
    def state_file(self):
        return os.path.join(self.state_dir, "state.json")

    def window(self, today):
        return (
            today - datetime.timedelta(days=self.back_days),
            today + datetime.timedelta(days=self.fwd_days),
        )


# ── ICS parsing ────────────────────────────────────────────────────────────────
# Deliberately a line splitter rather than an iCalendar library: nicos-scripts is
# stdlib-only (pyproject.toml), and the job here is to DROP components, never to
# rewrite them. Kept components are emitted as their original physical lines, so
# whatever Google sent — folding, escaping, X- properties, VALARMs — survives
# byte-for-byte and there is no re-folding bug to have.


def split_lines(text):
    """Physical lines, newline style normalised, trailing blank dropped."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def unfold(lines):
    """RFC 5545 §3.1 unfolding: a leading space/tab continues the previous line."""
    out = []
    for line in lines:
        if out and line[:1] in (" ", "\t"):
            out[-1] += line[1:]
        else:
            out.append(line)
    return out


def prop_value(logical_lines, name):
    """First value of `name`, or None.

    Scans the component FLAT — safe here because the only nested components are
    VALARM (inside VEVENT), which carries TRIGGER/ACTION but never DTSTART/UID/RRULE,
    and STANDARD/DAYLIGHT (inside VTIMEZONE), which we never window.
    """
    for line in logical_lines:
        head, _, value = line.partition(":")
        if head.split(";", 1)[0].upper() == name:
            return value
    return None


def prop_params(logical_lines, name):
    for line in logical_lines:
        head, _, _ = line.partition(":")
        if head.split(";", 1)[0].upper() == name:
            return head
    return ""


def parse(text):
    """Return (header_lines, components) for a VCALENDAR.

    `header_lines` are the top-level properties before the first sub-component;
    each component is a dict with its name, original physical lines and unfolded
    logical lines.
    """
    lines = split_lines(text)
    header, components = [], []
    current, depth = None, 0

    for line in lines:
        stripped = line.strip()
        upper = stripped.upper()
        if upper.startswith("BEGIN:") and upper != "BEGIN:VCALENDAR":
            if current is None:
                current = {"name": upper[6:], "lines": [line]}
                depth = 1
            else:
                depth += 1
                current["lines"].append(line)
            continue
        if current is not None:
            current["lines"].append(line)
            if upper.startswith("END:"):
                depth -= 1
                if depth == 0:
                    current["logical"] = unfold(current["lines"])
                    components.append(current)
                    current = None
            continue
        if upper in ("BEGIN:VCALENDAR", "END:VCALENDAR"):
            continue
        header.append(line)

    return header, components


DATE_RE = re.compile(r"(\d{8})")


def as_date(value):
    """Date part of any DTSTART/DTEND/UNTIL/RECURRENCE-ID form, or None.

    Covers `VALUE=DATE:20260915`, `TZID=Europe/Paris:20260915T090000` and
    `:20260915T070000Z` alike — only the leading YYYYMMDD is ever needed, because
    the window is measured in whole days.
    """
    if not value:
        return None
    m = DATE_RE.search(value)
    if not m:
        return None
    try:
        return datetime.date(int(m.group(1)[:4]), int(m.group(1)[4:6]), int(m.group(1)[6:8]))
    except ValueError:
        return None


def rrule_end(rrule, start):
    """Last date an RRULE can produce, or None when it never stops.

    UNTIL is exact. COUNT cannot be resolved without expanding the rule, so it
    reports None (= unbounded) and the event is KEPT — over-keeping one event is
    cheaper than silently losing a live series. This feed has exactly one such rule.
    """
    if not rrule:
        return start
    fields = dict(
        part.split("=", 1) for part in rrule.split(";") if "=" in part
    )
    until = fields.get("UNTIL")
    if until:
        return as_date(until)
    return None


def classify(component):
    """(uid, is_override, first_date, last_date) for a VEVENT.

    `last_date` is None when the component recurs forever.
    """
    logical = component["logical"]
    uid = prop_value(logical, "UID")
    recurrence_id = prop_value(logical, "RECURRENCE-ID")
    start = as_date(prop_value(logical, "DTSTART"))
    end = as_date(prop_value(logical, "DTEND")) or start
    rrule = prop_value(logical, "RRULE")

    if recurrence_id is not None:
        # An override replaces ONE occurrence; its own dates are the whole story.
        return uid, True, start, end
    return uid, False, start, rrule_end(rrule, end)


def select(components, lo, hi):
    """Names of components to keep, as a set of ids (index into `components`).

    Three rules, in order:
      1. Every VTIMEZONE is kept. They are few (one here) and a kept event whose
         TZID vanished renders at the wrong offset.
      2. A VEVENT is kept when [first_date, last_date] overlaps the window, where
         a None last_date means "forever".
      3. A master is kept when ANY override sharing its UID is kept. Without this
         a surviving exception becomes an orphan — 2749 of this feed's 6234
         components are overrides, so it is the common case, not an edge one.

    ⚠ An orphan in the OUTPUT is not necessarily a bug here. Google exports 6 UIDs
      that have no master in the source at all (measured 2026-09-15) — a modified
      instance whose series was deleted, or whose master predates Google's own
      export horizon. Rule 3 cannot invent a master that upstream never sent, and
      passing the override through unchanged is what every client already sees on
      the direct feed.
    """
    keep = set()
    kept_uids = set()
    masters = {}

    for i, comp in enumerate(components):
        if comp["name"] != "VEVENT":
            if comp["name"] == "VTIMEZONE":
                keep.add(i)
            continue

        uid, is_override, first, last = classify(comp)
        if not is_override:
            masters.setdefault(uid, i)

        if first is None:
            # Undated component: keep it rather than guess. None exist in this
            # feed today, but dropping something unparseable is the worse failure.
            keep.add(i)
            kept_uids.add(uid)
            continue

        starts_before_end = first <= hi
        ends_after_start = last is None or last >= lo
        if starts_before_end and ends_after_start:
            keep.add(i)
            kept_uids.add(uid)

    for uid in kept_uids:
        master = masters.get(uid)
        if master is not None:
            keep.add(master)

    return keep


def render(header, components, keep):
    """Emit a VCALENDAR of the kept components, CRLF-terminated per RFC 5545 §3.1.

    Output order is imposed rather than inherited, for the reason spelled out in
    `canonical_digest`: upstream's order is not stable between fetches, and a served
    file that reshuffles itself on every write is needlessly hard to diff. VTIMEZONEs
    keep their original relative order and lead; VEVENTs follow in `sort_key` order.
    """
    out = ["BEGIN:VCALENDAR"]
    wanted = {p.upper() for p in HEADER_PROPS}
    for line in header:
        if prop_name(line) in wanted:
            out.append(line)

    kept = [components[i] for i in sorted(keep)]
    zones = [c for c in kept if c["name"] == "VTIMEZONE"]
    rest = sorted((c for c in kept if c["name"] != "VTIMEZONE"), key=sort_key)
    for comp in zones + rest:
        out.extend(comp["lines"])

    out.append("END:VCALENDAR")
    return "\r\n".join(out) + "\r\n"


# Properties regenerated by the exporter on every fetch, so a difference in them is
# not a change to the calendar. DTSTAMP is "when this object was written out"; real
# edits move SEQUENCE / LAST-MODIFIED, which are deliberately NOT in this set.
VOLATILE_PROPS = frozenset({"DTSTAMP"})


def prop_name(line):
    return line.partition(":")[0].split(";", 1)[0].upper()


def sort_key(component):
    """Deterministic order for the rendered output.

    (UID, RECURRENCE-ID, DTSTART): an empty RECURRENCE-ID sorts first, so a master
    always precedes its own overrides — the order a naive parser expects.
    """
    logical = component["logical"]
    return (
        prop_value(logical, "UID") or "",
        prop_value(logical, "RECURRENCE-ID") or "",
        prop_value(logical, "DTSTART") or "",
    )


def canonical_digest(header, components, indices):
    """Order-independent sha256 of a calendar, ignoring export-time-only properties.

    ⚠ ORDER IS NOT CONTENT. Google returns the very same events in a DIFFERENT order
      on every fetch — two fetches seconds apart share a UID multiset but diverge at
      index 0 (measured 2026-09-15). An order-sensitive hash therefore never matches,
      which silently defeats the write-skip and `last_changed_at` alike. Serialised
      component blocks are sorted before hashing so only real content counts.
    """
    blocks = sorted(
        "\r\n".join(l for l in components[i]["logical"] if prop_name(l) not in VOLATILE_PROPS)
        for i in indices
    )
    head = [l for l in header if prop_name(l) not in VOLATILE_PROPS]
    payload = "\r\n".join(head) + "\n\x00\n" + "\n\x00\n".join(blocks)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def window_ics(text, lo, hi):
    """Full pipeline: parse → select → render. Returns (ics_text, stats)."""
    header, components = parse(text)
    keep = select(components, lo, hi)
    events = [i for i, c in enumerate(components) if c["name"] == "VEVENT"]
    stats = {
        "events_in": len(events),
        "events_out": sum(1 for i in events if i in keep),
    }
    return render(header, components, keep), stats


# ── I/O ────────────────────────────────────────────────────────────────────────


def fetch(url, timeout, opener=None):
    """GET `url`, transparently gunzipping. Returns the decoded body.

    Gzip is requested explicitly because urllib never negotiates it, and this feed
    is 10x smaller compressed. See the module header for why no validator is sent.
    """
    opener = opener or urllib.request.urlopen
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "text/calendar, text/plain",
            "Accept-Encoding": "gzip",
            "User-Agent": "nic-os ics-mirror",
        },
    )
    with opener(req, timeout=timeout) as resp:
        body = resp.read()
        encoding = (resp.headers.get("Content-Encoding") or "").lower()
    if "gzip" in encoding:
        body = gzip.decompress(body)
    return body.decode("utf-8", errors="replace")


def load_feeds(path):
    """Parse the agenix feeds file. Raises with a pointed message on bad shape."""
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict) or not data:
        raise ValueError("feeds file must be a non-empty JSON object of slug -> url")
    for slug, url in data.items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", slug):
            raise ValueError(f"feed slug {slug!r} must be lowercase [a-z0-9_-]")
        if not url.startswith("https://"):
            raise ValueError(f"feed {slug!r} must be an https:// URL")
    return data


def write_atomic(path, text):
    """tmp + os.replace, so nginx never serves a half-written calendar."""
    tmp = f"{path}.tmp"
    with open(tmp, "w", newline="") as f:
        f.write(text)
    os.replace(tmp, path)


def mirror_feed(cfg, slug, url, lo, hi, state, dry_run, opener=None, now=None):
    """Fetch, window and (unless unchanged or dry) write one feed. Returns its stats."""
    now = now or datetime.datetime.now
    raw = fetch(url, cfg.timeout, opener=opener)

    prior = state.get(slug, {})
    window_key = f"{lo.isoformat()}..{hi.isoformat()}"
    out_path = os.path.join(cfg.out_dir, f"{slug}.ics") if cfg.out_dir else None

    # One parse feeds the render and both digests — the source is ~10 MB, so parsing
    # it twice would be the most expensive thing this script does.
    header, components = parse(raw)
    keep = select(components, lo, hi)
    body = render(header, components, keep)
    events = [i for i, c in enumerate(components) if c["name"] == "VEVENT"]
    stats = {
        "events_in": len(events),
        "events_out": sum(1 for i in events if i in keep),
    }

    # TWO digests, because they answer two different questions.
    #
    #   digest        — of the OUTPUT: "is the file on disk already what we would
    #                   write?" It subsumes the window, so a slide that changes which
    #                   components qualify rewrites, and a slide that changes nothing
    #                   correctly does not.
    #   source_digest — of the SOURCE: "did Google publish anything?" This one must
    #                   NOT see our window, or `last_changed_at` would measure our own
    #                   boundary crossings instead of upstream's publishing cadence,
    #                   which is the one thing it exists to measure.
    digest = canonical_digest(header, components, keep)
    source_digest = canonical_digest(header, components, range(len(components)))
    stats["digest"] = digest

    # A dry run, or a Config with no out_dir, must leave no trace: report and stop
    # before any write — of the calendar OR of the state file.
    if dry_run or not out_path:
        reason = "dry-run" if dry_run else "ICS_MIRROR_OUT_DIR unset"
        log(
            f"{slug}: {stats['events_in']} -> {stats['events_out']} events "
            f"({len(body)} bytes), NOT written ({reason})"
        )
        stats["written"] = False
        return stats

    if prior.get("digest") == digest and os.path.exists(out_path):
        log(f"{slug}: unchanged ({stats['events_in']} events upstream), skipping write")
        stats["written"] = False
    else:
        write_atomic(out_path, body)
        log(
            f"{slug}: {stats['events_in']} -> {stats['events_out']} events, "
            f"{len(body)} bytes -> {out_path}"
        )
        stats["written"] = True

    stamp = now().isoformat(timespec="seconds")
    # Deliberately updated on the skip path too. Google can publish a change that
    # falls entirely outside our window — the served file is rightly untouched, but
    # upstream DID move, and a cadence measurement that ignored those would
    # under-report exactly the lag it exists to quantify.
    published = prior.get("source_digest") != source_digest
    state[slug] = {
        "digest": digest,
        "source_digest": source_digest,
        "window": window_key,
        "events_in": stats["events_in"],
        "events_out": stats["events_out"],
        "bytes": len(body),
        # Last time the SERVED file changed.
        "written_at": stamp if stats["written"] else prior.get("written_at"),
        # Last time GOOGLE changed anything, window or no window. The gap between
        # two of these is the feed's real publishing cadence. See the header.
        "last_changed_at": stamp if published else prior.get("last_changed_at"),
    }
    return stats


def run(cfg, dry_run=False, opener=None, today=None, now=None):
    """Mirror every configured feed. Returns the process exit code."""
    if not cfg.feeds_file:
        log("FATAL: ICS_MIRROR_FEEDS_FILE is unset")
        return 1
    try:
        feeds = load_feeds(cfg.feeds_file)
    except (OSError, ValueError) as e:
        log(f"FATAL: cannot read feeds file {cfg.feeds_file}: {e}")
        return 1

    today = today or datetime.date.today()
    lo, hi = cfg.window(today)
    log(f"window {lo} .. {hi} ({len(feeds)} feed(s))")

    if cfg.out_dir and not dry_run:
        ensure_dir(cfg.out_dir)
    ensure_dir(cfg.state_dir)
    state = load_json(cfg.state_file, {})

    failed = 0
    for slug, url in sorted(feeds.items()):
        try:
            mirror_feed(cfg, slug, url, lo, hi, state, dry_run, opener=opener, now=now)
        except Exception as e:
            # One bad feed must not stop the others: a stale .ics for this slug is
            # far better than no refresh at all for every other slug.
            log(f"{slug}: FAILED: {type(e).__name__}: {e}")
            failed += 1

    if not dry_run:
        save_json(cfg.state_file, state, indent=2, sort_keys=True)

    if failed:
        log(f"{failed} of {len(feeds)} feed(s) failed")
    return 1 if failed == len(feeds) else 0


def main():
    cfg = Config.from_env(os.environ)
    sys.exit(run(cfg, dry_run="--dry-run" in sys.argv))


if __name__ == "__main__":
    main()
