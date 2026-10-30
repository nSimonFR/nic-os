"""Telegram report of earlyoom kills, one message per memory-pressure episode.

Kills less than QUIET_SEC apart share an episode. Its message lists every kill,
whether the victim's unit came back, the memory left at the last kill and the
units holding the most memory. It is sent silently, and pings (a reply) only when
a victim's unit is still down after GRACE_SEC, or on a storm of real kills.

A kill's unit comes from the victim's last journal line, so a process that never
logged (a Claude session, a Ryot sandbox) has none and is not tracked.
"""

import html
import json
import os
import re
import time

from ..httpjson import post_form
from ..logs import logger
from ..secrets import env_int, env_str, read_secret
from ..state import load_json, save_json

TAG = "earlyoom-alert"
TITLE = "earlyoom: memory pressure on rpi5"

QUIET_SEC = 30 * 60
GRACE_SEC = 5 * 60
# Non-expendable kills in one episode before it pings.
STORM_KILLS = 4
# oom_score_adj 1000: the process asks to be killed first (ryot-sandboxd does).
EXPENDABLE_ADJ = 1000
TOP_UNITS = 5
MAX_LINES = 15

KILL_RE = re.compile(
    r'sending (SIG\w+) to process (\d+) uid (\d+) "([^"]*)":'
    r".*?oom_score_adj (-?\d+), VmRSS (\d+) MiB"
)
MEM_RE = re.compile(r"mem avail:\s+(\d+) of\s+(\d+) MiB \(\s*([\d.]+)%\)")


class Config:
    token_file: str = ""
    chat_id: str = ""
    state_dir: str = "."
    journalctl: str = "journalctl"
    systemctl: str = "systemctl"
    proc: str = "/proc"
    quiet_sec: int = QUIET_SEC
    grace_sec: int = GRACE_SEC

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    @classmethod
    def from_env(cls, env=None):
        return cls(
            token_file=env_str("TELEGRAM_TOKEN_FILE", "", env),
            chat_id=env_str("TELEGRAM_CHAT_ID", "", env),
            state_dir=env_str("STATE_DIRECTORY", ".", env),
            journalctl=env_str("JOURNALCTL_BIN", "journalctl", env),
            systemctl=env_str("SYSTEMCTL_BIN", "systemctl", env),
            quiet_sec=env_int("QUIET_SEC", QUIET_SEC, env),
            grace_sec=env_int("GRACE_SEC", GRACE_SEC, env),
        )


# ── journal ──────────────────────────────────────────────────────────────────

def read_entries(cfg, cursor, run):
    """earlyoom's journal entries after `cursor` (the last 3 min on a cold start)."""
    cmd = [cfg.journalctl, "-u", "earlyoom", "-o", "json", "--no-pager"]
    cmd += [f"--after-cursor={cursor}"] if cursor else ["--since=-3min"]
    out = []
    for line in run(cmd).splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def parse_kills(entries):
    """(kills, last mem-avail reading) from earlyoom's lines, oldest first."""
    kills, mem = [], None
    for e in entries:
        msg = e.get("MESSAGE")
        if not isinstance(msg, str):
            continue
        m = MEM_RE.search(msg)
        if m:
            mem = {"avail": int(m[1]), "total": int(m[2]), "pct": float(m[3])}
            continue
        m = KILL_RE.search(msg)
        if m:
            kills.append({
                "ts": int(e.get("__REALTIME_TIMESTAMP", 0)) / 1e6,
                "signal": m[1],
                "pid": int(m[2]),
                "uid": int(m[3]),
                "name": m[4],
                "adj": int(m[5]),
                "rss": int(m[6]),
            })
    return kills, mem


def unit_of(cfg, kill, run):
    """(unit, uid of its user manager or None) from the victim's last journal line."""
    until = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(kill["ts"] + 1))
    out = run([cfg.journalctl, f"_PID={kill['pid']}", f"--until={until}",
               "-n", "1", "-o", "json", "--no-pager"])
    for line in out.splitlines()[-1:]:
        try:
            e = json.loads(line)
        except ValueError:
            return None, None
        if e.get("_SYSTEMD_USER_UNIT"):
            return e["_SYSTEMD_USER_UNIT"], int(e.get("_UID", kill["uid"]))
        unit = e.get("_SYSTEMD_UNIT")
        # A user manager or a session scope says nothing about the victim itself.
        if unit and not unit.startswith("user@") and not unit.endswith(".scope"):
            return unit, None
    return None, None


def is_active(cfg, unit, user_uid, run, user_name):
    cmd = [cfg.systemctl]
    if user_uid is not None:
        name = user_name(user_uid)
        if not name:
            return False
        cmd += [f"--machine={name}@.host", "--user"]
    return run(cmd + ["is-active", unit]).strip() == "active"


# ── memory snapshot ──────────────────────────────────────────────────────────

def unit_from_cgroup(text):
    path = text.strip().split("::", 1)[-1] if text else ""
    last = path.rstrip("/").rsplit("/", 1)[-1]
    return last or None


def proc_kib(proc, pid):
    """PSS in KiB (shared pages split between sharers), RSS when that is unreadable."""
    for name, key in (("smaps_rollup", "Pss:"), ("status", "VmRSS:")):
        try:
            with open(f"{proc}/{pid}/{name}") as f:
                for line in f:
                    if line.startswith(key):
                        return int(line.split()[1])
        except (OSError, ValueError, IndexError):
            continue
    return 0


def top_units(proc, listdir=os.listdir):
    """[(unit, MiB)] of the units holding the most memory, largest first."""
    by_unit = {}
    for pid in listdir(proc):
        if not pid.isdigit():
            continue
        try:
            with open(f"{proc}/{pid}/cgroup") as f:
                unit = unit_from_cgroup(f.read())
        except OSError:
            continue
        if not unit:
            continue
        by_unit[unit] = by_unit.get(unit, 0) + proc_kib(proc, pid)
    ranked = sorted(by_unit.items(), key=lambda kv: -kv[1])[:TOP_UNITS]
    return [(u, kib // 1024) for u, kib in ranked if kib >= 1024]


# ── episode ──────────────────────────────────────────────────────────────────

def add_kills(episode, kills):
    """Append kills, folding a SIGKILL that follows a SIGTERM on the same pid."""
    seen = {k["pid"] for k in episode["kills"]}
    added = []
    for k in kills:
        if k["pid"] in seen:
            continue
        seen.add(k["pid"])
        episode["kills"].append(k)
        added.append(k)
    if added:
        episode["last_kill"] = max(k["ts"] for k in added)
    return added


def refresh_status(cfg, episode, now, check):
    """Set each tracked kill's status: back, pending, or down after the grace."""
    for k in episode["kills"]:
        if not k.get("unit") or k.get("status") == "back":
            continue
        if check(k["unit"], k.get("user_uid")):
            k["status"] = "back"
        else:
            k["status"] = "down" if now - k["ts"] >= cfg.grace_sec else "pending"


def is_expendable(kill):
    return kill["adj"] >= EXPENDABLE_ADJ


def pings_due(cfg, episode):
    """[(key, HTML text)] for escalations not yet sent in this episode."""
    sent = set(episode.get("pinged", []))
    out = []
    for k in episode["kills"]:
        key = f"down:{k['pid']}"
        if k.get("status") == "down" and key not in sent:
            out.append((key, f"🔴 <code>{esc(k['unit'])}</code> still down "
                             f"{cfg.grace_sec // 60} min after earlyoom killed "
                             f"<code>{esc(k['name'])}</code>"))
    real = [k for k in episode["kills"] if not is_expendable(k)]
    if len(real) >= STORM_KILLS and "storm" not in sent:
        out.append(("storm", f"🔴 earlyoom storm: {len(real)} kills since "
                             f"{hhmm(episode['start'])}"))
    return out


def is_over(cfg, episode, now):
    return now - episode["last_kill"] >= cfg.quiet_sec


# ── rendering ────────────────────────────────────────────────────────────────

def esc(s):
    return html.escape(str(s), quote=False)


def hhmm(ts):
    return time.strftime("%H:%M", time.localtime(ts))


STATUS = {"back": " ↻ back", "pending": " … restarting", "down": " ✗ still down"}


def kill_line(k):
    unit = f" · {esc(k['unit'])}" if k.get("unit") else ""
    return (f"{hhmm(k['ts'])}  <code>{esc(k['name'])}</code> {k['rss']} MiB"
            f"{unit}{STATUS.get(k.get('status'), '')}")


def render(episode, now, over):
    real = [k for k in episode["kills"] if not is_expendable(k)]
    lines = [f"<b>{TITLE}</b>"]
    lines += [kill_line(k) for k in real[-MAX_LINES:]]
    if len(real) > MAX_LINES:
        lines.append(f"… and {len(real) - MAX_LINES} earlier")
    spare = {}
    for k in episode["kills"]:
        if is_expendable(k):
            n, rss = spare.get(k["name"], (0, 0))
            spare[k["name"]] = (n + 1, rss + k["rss"])
    for name, (n, rss) in sorted(spare.items()):
        lines.append(f"<code>{esc(name)}</code> ×{n}, {rss} MiB "
                     f"(oom_score_adj {EXPENDABLE_ADJ}, killed first)")
    mem = episode.get("mem")
    if mem:
        lines.append(f"\nmem avail at last kill: {mem['avail']} of {mem['total']} MiB "
                     f"({mem['pct']:.1f}%)")
    if episode.get("top"):
        top = " · ".join(f"{esc(u.removesuffix('.service'))} {mib}"
                         for u, mib in episode["top"])
        lines.append(f"top memory (MiB) at {hhmm(episode['top_at'])}: {top}")
    n = len(episode["kills"])
    span = max(1, round((episode["last_kill"] - episode["start"]) / 60))
    if over:
        foot = f"✅ ended {hhmm(now)} · {n} kill{'s' * (n != 1)} in {span} min"
    else:
        foot = f"⚠ ongoing since {hhmm(episode['start'])} · {n} kill{'s' * (n != 1)} · updated {hhmm(now)}"
    lines.append(f"\n<i>{foot}</i>")
    return "\n".join(lines)


# ── telegram ─────────────────────────────────────────────────────────────────

class Telegram:
    def __init__(self, token, chat_id, opener=None, log=print):
        self.api = f"https://api.telegram.org/bot{token}"
        self.chat_id = chat_id
        self.opener = opener
        self.log = log

    def call(self, method, **fields):
        fields = {"chat_id": self.chat_id, "parse_mode": "HTML",
                  "disable_web_page_preview": "true", **fields}
        try:
            return post_form(f"{self.api}/{method}", fields, opener=self.opener)
        except Exception as e:  # noqa: BLE001 — a failed send must not lose state
            self.log(f"{method} failed: {type(e).__name__}")
            return {}

    def send(self, text, silent=False, reply_to=None):
        fields = {"text": text}
        if silent:
            fields["disable_notification"] = "true"
        if reply_to:
            fields["reply_parameters"] = json.dumps({"message_id": reply_to})
        return (self.call("sendMessage", **fields).get("result") or {}).get("message_id")

    def edit(self, mid, text):
        return bool(self.call("editMessageText", message_id=mid, text=text).get("ok"))


class LogOnly:
    def __init__(self, log):
        self.log = log

    def send(self, text, silent=False, reply_to=None):
        self.log(text)
        return 1

    def edit(self, mid, text):
        self.log(text)
        return True


# ── main loop ────────────────────────────────────────────────────────────────

def tick(cfg, state, now, run, tg, snapshot, user_name, log):
    """One timer run: fold new kills into the episode, update the message."""
    entries = read_entries(cfg, state.get("cursor"), run)
    if entries:
        state["cursor"] = entries[-1].get("__CURSOR") or state.get("cursor")
    kills, mem = parse_kills(entries)

    episode = state.get("episode")
    if kills and episode is None:
        episode = state["episode"] = {"start": kills[0]["ts"], "last_kill": kills[0]["ts"],
                                      "kills": [], "pinged": []}
    if episode is None:
        return state

    added = add_kills(episode, kills)
    for k in added:
        k["unit"], k["user_uid"] = unit_of(cfg, k, run)
    if mem:
        episode["mem"] = mem
    if added:
        episode["top"], episode["top_at"] = snapshot(), now
        log(f"{len(added)} kill(s): " + ", ".join(k["name"] for k in added))

    refresh_status(cfg, episode, now,
                   lambda unit, uid: is_active(cfg, unit, uid, run, user_name))
    over = is_over(cfg, episode, now)
    text = render(episode, now, over)

    if not episode.get("mid"):
        episode["mid"] = tg.send(text, silent=True)
        episode["text"] = text
    elif text != episode.get("text") and tg.edit(episode["mid"], text):
        episode["text"] = text

    for key, ping in pings_due(cfg, episode):
        if tg.send(ping, reply_to=episode.get("mid")):
            episode["pinged"].append(key)

    if over:
        state["episode"] = None
    return state


def main(argv=None, env=None, run=None, opener=None, now=None, log=None):
    import pwd
    import subprocess

    cfg = Config.from_env(env)
    log = log or logger(TAG)
    if run is None:
        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout

    def user_name(uid):
        try:
            return pwd.getpwuid(uid).pw_name
        except KeyError:
            return None

    if cfg.token_file and cfg.chat_id:
        tg = Telegram(read_secret(cfg.token_file), cfg.chat_id, opener=opener, log=log)
    else:
        log("no TELEGRAM_TOKEN_FILE/TELEGRAM_CHAT_ID: logging instead of sending")
        tg = LogOnly(log)

    path = os.path.join(cfg.state_dir, "state.json")
    state = load_json(path, {})
    state = tick(cfg, state, now or time.time(), run, tg,
                 lambda: top_units(cfg.proc), user_name, log)
    save_json(path, state)
    return 0

