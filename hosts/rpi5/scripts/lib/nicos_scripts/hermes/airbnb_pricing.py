#!/usr/bin/env python3
"""
hermes-airbnb-pricing: the facts behind a nightly price suggestion for the Zen flat.

Pre-run script of an AGENT cron job (skill `airbnb-pricing`): stdout is injected
into the prompt, and a last line of `{"wakeAgent": false}` skips the model run.

Two sources:
- the Airbnb export (bookings + host-blocked nights, future only), fetched straight
  from the URL stored as the `wwwairbnbcom` Nextcloud subscription. Nextcloud 33
  fetches it but caches 0 objects (2026-10-02), so its CalDAV copy is never read;
- PERSO `Airbnb · <guest> — …` events, the only record of past nights (the cap
  counts them) and of guest names.

Env: CALDAV_{BASE,USER,PASSWORD,PASSWORD_FILE}, AIRBNB_FEED_CALENDAR,
AIRBNB_RULES, AIRBNB_STATE, AIRBNB_TODAY (YYYY-MM-DD, for a hand run).
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from xml.etree import ElementTree

from ..logs import logger
from ..secrets import env_str, read_secret
from ..state import ensure_dir, load_json, save_json
from . import calendar_digest as cal

log = logger("hermes-airbnb-pricing", lambda: sys.stderr)

BOOKING_PREFIX = "Airbnb · "
RESERVED = "Reserved"
SILENT = '{"wakeAgent": false}'


@dataclass(frozen=True)
class Config:
    base: str = cal.DEFAULT_BASE
    user: str = "nsimon"
    password: str = ""
    feed_calendar: str = "wwwairbnbcom"
    bookings_calendar: str = "personal"
    rules_path: str = ""
    state_path: str = ""
    today: date | None = None

    @classmethod
    def from_env(cls, env=None):
        hermes_home = env_str("HERMES_HOME", "", env) or os.path.expanduser("~/.hermes")
        password = env_str("CALDAV_PASSWORD", "", env)
        if not password:
            try:
                password = read_secret(
                    env_str("CALDAV_PASSWORD_FILE", cal.DEFAULT_PASSWORD_FILE, env)
                )
            except OSError:
                password = ""
        today = env_str("AIRBNB_TODAY", "", env)
        return cls(
            base=env_str("CALDAV_BASE", cal.DEFAULT_BASE, env).rstrip("/") + "/",
            user=env_str("CALDAV_USER", "nsimon", env),
            password=password.strip(),
            feed_calendar=env_str("AIRBNB_FEED_CALENDAR", "wwwairbnbcom", env),
            rules_path=env_str(
                "AIRBNB_RULES", f"{hermes_home}/skills/airbnb-pricing/rules.json", env
            ),
            state_path=env_str(
                "AIRBNB_STATE", f"{hermes_home}/workspace/airbnb-pricing/state.json", env
            ),
            today=date.fromisoformat(today) if today else None,
        )


# ── I/O ──────────────────────────────────────────────────────────────────────


def _auth(cfg):
    return "Basic " + base64.b64encode(f"{cfg.user}:{cfg.password}".encode()).decode()


def subscription_source(cfg, opener=None):
    """The remote URL behind a Nextcloud calendar subscription."""
    req = urllib.request.Request(
        f"{cfg.base}{cfg.feed_calendar}/",
        data=(
            '<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">'
            "<d:prop><cs:source/></d:prop></d:propfind>"
        ).encode(),
        method="PROPFIND",
        headers={"Authorization": _auth(cfg), "Depth": "0",
                 "Content-Type": 'application/xml; charset="utf-8"'},
    )
    with (opener or urllib.request.urlopen)(req, timeout=30) as resp:
        root = ElementTree.fromstring(resp.read())
    for href in root.iter("{DAV:}href"):
        if href.text and href.text.startswith("http"):
            return href.text.strip()
    raise ValueError(f"{cfg.feed_calendar} is not a subscription (no cs:source)")


def fetch_text(url, opener=None):
    req = urllib.request.Request(url, headers={"User-Agent": "nic-os/airbnb-pricing"})
    with (opener or urllib.request.urlopen)(req, timeout=30) as resp:
        return resp.read().decode("utf-8", "replace")


def year_bookings(cfg, year, opener=None):
    """PERSO Airbnb stays overlapping `year`, as dicts with guest/start/end."""
    lo = datetime(year, 1, 1, tzinfo=cal.UTC)
    hi = datetime(year + 1, 1, 1, tzinfo=cal.UTC)
    view = cal.Config(
        base=cfg.base, user=cfg.user, password=cfg.password, calendar=cfg.bookings_calendar
    )
    blobs = cal.report(view, cal.query_body(lo, hi, expand=False), opener=opener)
    out = []
    for blob in blobs:
        for comp in parse_events(blob):
            summary = comp["summary"]
            if summary.startswith(BOOKING_PREFIX):
                guest = summary[len(BOOKING_PREFIX):].split(" — ")[0].strip()
                out.append({**comp, "guest": guest})
    return out


# ── parsing ──────────────────────────────────────────────────────────────────


def _as_date(value):
    v = value.strip()
    return date(int(v[0:4]), int(v[4:6]), int(v[6:8]))


def parse_events(blob):
    """All-day VEVENTs as {start, end, summary}; `end` is the checkout day."""
    out = []
    for comp in cal.parse_components(blob):
        start = _as_date(comp["dtstart"][1])
        end = _as_date(comp["dtend"][1]) if "dtend" in comp else start + timedelta(days=1)
        out.append({"start": start, "end": end, "summary": comp.get("summary") or ""})
    return out


def nights(start, end):
    return {start + timedelta(days=i) for i in range((end - start).days)}


# ── pricing ──────────────────────────────────────────────────────────────────


def lead_tier(rules, lead_days):
    """The first ladder step whose `max_lead_days` covers this lead, else 0%."""
    for step in sorted(rules["lead_time_ladder"], key=lambda s: s["max_lead_days"]):
        if lead_days <= step["max_lead_days"]:
            return step
    return {"max_lead_days": None, "discount_pct": 0}


def nightly_price(rules, night, lead_days, cap_binding):
    base = rules["base_price"].get(f"{night:%Y-%m}", rules["default_base_price"])
    if night.weekday() in (4, 5):  # Friday and Saturday nights
        base *= 1 + rules["weekend_pct"] / 100
    price = base * (1 - lead_tier(rules, lead_days)["discount_pct"] / 100)
    floor = rules["floor"]["cap_binding" if cap_binding else "cap_free"]
    return round(max(price, floor))


def host_net(rules, gross):
    fee = rules["host_fee_pct"] / 100 * (1 + rules["vat_pct"] / 100)
    return round(gross * (1 - fee), 2)


def price_runs(rules, run, prices):
    """Consecutive nights at one price → one {first_night, last_night, price, net}."""
    out = []
    for night, price in zip(run, prices):
        if out and out[-1]["price"] == price and out[-1]["_last"] == night - timedelta(days=1):
            out[-1]["_last"] = night
        else:
            out.append({"_first": night, "_last": night, "price": price})
    return [
        {"first_night": r["_first"].isoformat(), "last_night": r["_last"].isoformat(),
         "price": r["price"], "net": host_net(rules, r["price"])}
        for r in out
    ]


# ── facts ────────────────────────────────────────────────────────────────────


def build_facts(rules, feed_events, bookings, today):
    season_end = date.fromisoformat(rules["season_end"])  # last sellable night
    year = today.year

    reserved_ranges = sorted(
        (e["start"], e["end"]) for e in feed_events if e["summary"] == RESERVED
    )
    feed_reserved = set().union(*(nights(s, e) for s, e in reserved_ranges))
    blocked = set().union(
        *(nights(e["start"], e["end"]) for e in feed_events if e["summary"] != RESERVED)
    )
    perso = set().union(*(nights(b["start"], b["end"]) for b in bookings))
    booked = {n for n in feed_reserved | perso if n.year == year}

    horizon = [today + timedelta(days=i) for i in range((season_end - today).days + 1)]
    open_nights = [n for n in horizon if n not in booked and n not in blocked]

    cap = rules["cap_nights"]
    used = len(booked)
    cap_info = {
        "limit": cap,
        "used": used,
        "remaining": cap - used,
        "open_nights_left": len(open_nights),
        # More open nights than the cap allows → nights are scarce.
        "binding": len(open_nights) > cap - used,
    }

    gaps, run = [], []
    for n in open_nights:
        if run and n != run[-1] + timedelta(days=1):
            gaps.append(run)
            run = []
        run.append(n)
    if run:
        gaps.append(run)

    min_stay = rules["min_stay"]
    gap_facts = []
    for run in gaps:
        lead = (run[0] - today).days
        prices = [nightly_price(rules, n, (n - today).days, cap_info["binding"]) for n in run]
        orphan = len(run) < min_stay
        if orphan:
            prices = [round(p * (1 + rules["orphan_premium_pct"] / 100)) for p in prices]
        gap_facts.append(
            {
                "check_in": run[0].isoformat(),
                "check_out": (run[-1] + timedelta(days=1)).isoformat(),
                "nights": len(run),
                "lead_days": lead,
                "weekend_nights": sum(n.weekday() in (4, 5) for n in run),
                "bookable_at_min_stay": not orphan,
                "tier_discount_pct": lead_tier(rules, lead)["discount_pct"],
                "prices": price_runs(rules, run, prices),
            }
        )

    months = {}
    for n in horizon:
        m = months.setdefault(f"{n:%Y-%m}", {"sellable": 0, "booked": 0})
        if n not in blocked:
            m["sellable"] += 1
            m["booked"] += n in booked
    for m in months.values():
        m["occupancy_pct"] = round(100 * m["booked"] / m["sellable"]) if m["sellable"] else None

    future_feed = {n for n in feed_reserved if n >= today}
    future_perso = {n for n in perso if n >= today}
    upcoming = sorted(
        (b for b in bookings if b["end"] > today), key=lambda b: b["start"]
    )
    return {
        "today": today.isoformat(),
        "season_end": season_end.isoformat(),
        "cap": cap_info,
        "months": months,
        "gaps": gap_facts,
        "reserved": [[s.isoformat(), e.isoformat()] for s, e in reserved_ranges],
        "upcoming_guests": [
            {"guest": b["guest"], "check_in": b["start"].isoformat(),
             "check_out": b["end"].isoformat()}
            for b in upcoming
        ],
        "mismatch": {
            "in_airbnb_not_in_perso": sorted(n.isoformat() for n in future_feed - future_perso),
            "in_perso_not_in_airbnb": sorted(n.isoformat() for n in future_perso - future_feed),
        },
    }


def triggers(rules, facts, state, today):
    """Why the agent should run today, and the state to persist. Empty → silent."""
    reasons = []
    prev = {tuple(r) for r in state.get("reserved", [])}
    cur = {tuple(r) for r in facts["reserved"]}
    if state:  # first run has no baseline: everything would look "new"
        new = sorted(cur - prev)
        gone = sorted(r for r in prev - cur if r[1] > today.isoformat())
        reasons += [f"new_booking {s}→{e}" for s, e in new]
        reasons += [f"cancelled {s}→{e}" for s, e in gone]

    alerted = dict(state.get("alerted", {}))
    for gap in facts["gaps"]:
        if gap["lead_days"] > rules["urgent_lead_days"]:
            continue
        key = f"{gap['check_in']}|{gap['nights']}"
        if alerted.get(key) != gap["tier_discount_pct"]:
            alerted[key] = gap["tier_discount_pct"]
            reasons.append(f"urgent_gap {gap['check_in']} ({gap['nights']}n, J-{gap['lead_days']})")
    alerted = {k: v for k, v in alerted.items() if k.split("|")[0] >= today.isoformat()}

    weekly = (
        today.weekday() == rules["weekly_weekday"]
        and state.get("last_weekly") != today.isoformat()
    )
    if weekly:
        reasons.insert(0, "weekly_summary")

    season_over = today > date.fromisoformat(facts["season_end"]) or facts["cap"]["remaining"] <= 0
    if season_over and not state.get("season_over_notified"):
        reasons.append("season_over")

    new_state = {
        "reserved": sorted(list(r) for r in cur),
        "alerted": alerted,
        "last_weekly": today.isoformat() if weekly else state.get("last_weekly"),
        "season_over_notified": season_over,
    }
    return reasons, new_state


# ── entry point ──────────────────────────────────────────────────────────────


def run(cfg, rules, state, opener=None):
    today = cfg.today or datetime.now(cal.TZ).date()
    feed = parse_events(fetch_text(subscription_source(cfg, opener), opener))
    bookings = year_bookings(cfg, today.year, opener=opener)
    facts = build_facts(rules, feed, bookings, today)
    reasons, new_state = triggers(rules, facts, state, today)
    return facts, reasons, new_state


def main(argv=None, env=None):
    ap = argparse.ArgumentParser(prog="hermes-airbnb-pricing")
    ap.add_argument("--no-state", action="store_true",
                    help="read the state but never write it (hand runs)")
    ap.add_argument("--force", action="store_true", help="wake even with no trigger")
    args = ap.parse_args(argv)

    cfg = Config.from_env(env)
    if not cfg.password:
        log("FATAL: no CalDAV password (CALDAV_PASSWORD / CALDAV_PASSWORD_FILE)")
        return 1
    try:
        with open(cfg.rules_path) as f:
            rules = json.load(f)
    except (OSError, ValueError) as e:
        log(f"FATAL: cannot read rules {cfg.rules_path} ({e})")
        return 1
    state = load_json(cfg.state_path, {})
    try:
        facts, reasons, new_state = run(cfg, rules, state)
    except (urllib.error.URLError, OSError, ElementTree.ParseError, ValueError) as e:
        log(f"FATAL: {e}")
        return 1

    if not args.no_state:
        ensure_dir(os.path.dirname(cfg.state_path))
        save_json(cfg.state_path, new_state, indent=1, sort_keys=True)
    if args.force and not reasons:
        reasons = ["forced"]
    log(f"triggers={reasons or 'none'} gaps={len(facts['gaps'])} cap={facts['cap']}")
    if not reasons:
        print(SILENT)
        return 0
    print(json.dumps({"triggers": reasons, **facts}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
