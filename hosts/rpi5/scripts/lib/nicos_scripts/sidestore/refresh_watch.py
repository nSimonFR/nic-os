"""Alert when no SideStore refresh traffic has crossed the 10.7.0.1 hairpin.

SideStore's certs last 7 days, and every failure of this path so far has been
silent until one expired: the 0.6.4 anisette break ran 31h, a withdrawn subnet
route killed it outright, and a drifted RemotePairing port (upstream #1579) cost
another day. All three look identical from rpi5 — the hairpin counter stops
moving — so this asserts on the counter rather than on any one cause.

Deliberately NOT the alert condition: the phone polling a dead port. That is
only the 2026-09-22 failure, and it would have stayed silent through the other
two.

Emits the alert body on stdout, empty when healthy; the unit pipes that to
telegram-alert, which owns sending and dedup.
"""

import json
from datetime import datetime, timezone

from ..logs import logger
from ..secrets import env_int, env_str
from ..state import ensure_dir, load_json, save_json

TAG = "sidestore-refresh-watch"

DEFAULT_NFT = "nft"
DEFAULT_TABLE = "sidestore"
DEFAULT_STATE_DIR = "/var/lib/sidestore-refresh-watch"
# Certs last 7d. 5d leaves two days to act and, unlike a 48h threshold, does not
# assume a refresh cadence we have not measured yet.
DEFAULT_STALE_HOURS = 120

STATE_FILE = "counter.json"


class Config:
    nft: str = DEFAULT_NFT
    table: str = DEFAULT_TABLE
    state_dir: str = DEFAULT_STATE_DIR
    stale_hours: int = DEFAULT_STALE_HOURS

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    @classmethod
    def from_env(cls, env=None):
        return cls(
            nft=env_str("NFT_BIN", DEFAULT_NFT, env),
            table=env_str("SIDESTORE_NFT_TABLE", DEFAULT_TABLE, env),
            state_dir=env_str("STATE_DIR", DEFAULT_STATE_DIR, env),
            stale_hours=env_int("STALE_HOURS", DEFAULT_STALE_HOURS, env),
        )


# ── reading the counter ──────────────────────────────────────────────────────

def read_counter(cfg, run):
    """Total packets across every counter in the table, or None if unreadable.

    None covers both "table absent" (reflector stopped) and "no counter in the
    rule" (config skew) — each means the refresh path is not observable, which
    is itself worth paging on.
    """
    out = run([cfg.nft, "-j", "list", "table", "ip", cfg.table])
    try:
        items = json.loads(out)["nftables"]
    except (ValueError, KeyError, TypeError):
        return None

    total, found = 0, False
    for item in items:
        for expr in (item.get("rule") or {}).get("expr", []):
            counter = expr.get("counter")
            if isinstance(counter, dict) and "packets" in counter:
                total += counter["packets"]
                found = True
    return total if found else None


# ── the verdict ──────────────────────────────────────────────────────────────

def parse_iso(value):
    try:
        return datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None


def describe_age(hours):
    if hours is None:
        return "unknown"
    return f"{hours:.1f}h" if hours < 48 else f"{hours / 24:.1f}d"


def assess(prev, packets, now, stale_hours):
    """(body, state) — body is "" when healthy.

    A counter that went DOWN is a reset, not a stall: the table is recreated on
    every `systemctl restart sidestore-reflector` and on boot. Reading that as
    "no traffic" would page after each rebuild.
    """
    if packets is None:
        return (
            "nft table `ip sidestore` has no readable counter — the reflector is "
            "stopped, or the rule shipped without one.\n"
            "check: systemctl status sidestore-reflector",
            prev,
        )

    prev_packets = (prev or {}).get("packets")
    since = parse_iso((prev or {}).get("since")) if prev else None

    # Moved, reset, or first run — all restart the clock.
    if prev_packets is None or packets != prev_packets or since is None:
        return "", {"packets": packets, "since": now.isoformat()}

    state = {"packets": packets, "since": since.isoformat()}
    flat_for = (now - since).total_seconds() / 3600.0
    if flat_for <= stale_hours:
        return "", state

    return (
        f"no SideStore refresh traffic for {describe_age(flat_for)} "
        f"(threshold {describe_age(stale_hours)}), counter flat at {packets} packets\n"
        "certs expire 7d after the last refresh. Likeliest cause is a drifted "
        "RemotePairing port (SideStore#1579):\n"
        "  phone: Experimental Features > Network Discovery > local > "
        "_remotepairing._tcp -> port\n"
        "  then:  Connection Config > RemotePair Port\n"
        "route check: tailscale status --json | jq .Self.PrimaryRoutes "
        "(must contain 10.7.0.1/32)",
        state,
    )


def main(argv=None, env=None, run=None, now=None, log=None):
    import subprocess
    import sys

    cfg = Config.from_env(env)
    # stderr, not stdout: stdout IS the alert body.
    log = log or logger(TAG, stream=lambda: sys.stderr)
    if run is None:
        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True,
                                  check=False).stdout
    now = now or datetime.now(timezone.utc)

    path = f"{ensure_dir(cfg.state_dir)}/{STATE_FILE}"
    prev = load_json(path, None)
    packets = read_counter(cfg, run)

    body, state = assess(prev, packets, now, cfg.stale_hours)
    if state is not None:
        save_json(path, state)

    if body:
        print(body)
    else:
        log(f"ok — counter {packets}, unchanged since {(state or {}).get('since')}")
    return 0
