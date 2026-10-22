"""Alert on security state the Nix config cannot see.

hosts/rpi5/security-policy.nix refuses a bad config at eval time; this covers
what lives outside it:

- SSH keys in ~/.ssh/authorized_keys. sshd reads that file as well as the
  managed /etc/ssh/authorized_keys.d/, so a key dropped there by hand (or by a
  pairing tool) grants a login no commit shows.
- Funnel ports beyond the declared ones. A manual `tailscale funnel` puts a
  service on the internet until tailscale-serve.service next runs.
- SSH connections from outside the LAN/tailnet, i.e. a router port-forward.

Emits the alert body on stdout, empty when clean; the unit pipes it to
telegram-alert, which owns sending and dedup.
"""

import ipaddress
import json
import re

from ..logs import logger
from ..secrets import env_str

TAG = "security-drift"

# Loopback, RFC1918, link-local, Tailscale's CGNAT range and ULA prefix.
TRUSTED_NETS = [ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "::1/128",
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
    "169.254.0.0/16", "fe80::/10",
    "100.64.0.0/10", "fd7a:115c:a1e0::/48",
)]

# The peer in sshd's "from X port", "closed by X port", "user U X port" lines;
# never "on X port 22", which is the Pi's own address.
FROM_RE = re.compile(r"\b(?:from|by|user \S+) (\S+) port \d+")


class Config:
    allowed_keys: frozenset = frozenset()
    funnel_ports: frozenset = frozenset()
    users: tuple = ()
    tailscale: str = "tailscale"
    journalctl: str = "journalctl"
    ssh_keygen: str = "ssh-keygen"
    ip: str = "ip"
    since: str = "-1d"

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)

    @classmethod
    def from_env(cls, env=None):
        def words(name):
            return frozenset(env_str(name, "", env).split())
        return cls(
            allowed_keys=words("ALLOWED_KEY_FINGERPRINTS"),
            funnel_ports=words("FUNNEL_PORTS"),
            users=tuple(env_str("SSH_USERS", "root", env).split()),
            tailscale=env_str("TAILSCALE_BIN", "tailscale", env),
            journalctl=env_str("JOURNALCTL_BIN", "journalctl", env),
            ssh_keygen=env_str("SSH_KEYGEN_BIN", "ssh-keygen", env),
            ip=env_str("IP_BIN", "ip", env),
            since=env_str("SINCE", "-1d", env),
        )


# ── checks ───────────────────────────────────────────────────────────────────

def parse_fingerprints(keygen_out):
    """(fingerprint, comment) per line of `ssh-keygen -lf`."""
    out = []
    for line in keygen_out.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2 and parts[1].startswith("SHA256:"):
            out.append((parts[1], parts[2] if len(parts) > 2 else ""))
    return out


def unmanaged_keys(cfg, home_of, exists, run):
    """Lines for keys in a user's own authorized_keys that are not acknowledged."""
    lines = []
    for user in cfg.users:
        home = home_of(user)
        if not home:
            continue
        path = f"{home}/.ssh/authorized_keys"
        if not exists(path):
            continue
        for fp, comment in parse_fingerprints(run([cfg.ssh_keygen, "-lf", path])):
            if fp not in cfg.allowed_keys:
                lines.append(f"unmanaged SSH key for {user}: {fp} {comment}".rstrip())
    return lines


def funnel_ports(status_json):
    """Ports Tailscale currently funnels, from `tailscale funnel status --json`."""
    allow = (json.loads(status_json or "{}") or {}).get("AllowFunnel") or {}
    return {hostport.rsplit(":", 1)[1] for hostport, on in allow.items() if on}


def unexpected_funnels(cfg, run):
    try:
        live = funnel_ports(run([cfg.tailscale, "funnel", "status", "--json"]))
    except ValueError:
        return ["could not parse `tailscale funnel status --json`"]
    return [f"unexpected funnel on port {p} (declared: {' '.join(sorted(cfg.funnel_ports))})"
            for p in sorted(live - cfg.funnel_ports)]


def own_addrs(ip_json):
    """The host's own addresses, from `ip -j addr`. Its global IPv6 is not in
    any private range, and the Pi does ssh to itself."""
    return {a["local"] for link in json.loads(ip_json or "[]")
            for a in link.get("addr_info", []) if "local" in a}


def is_trusted(addr, own=frozenset()):
    addr = addr.split("%", 1)[0]
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return True  # not an address (hostname, "UNKNOWN"): nothing to classify
    return addr in own or any(ip in net for net in TRUSTED_NETS)


def external_ssh(cfg, run):
    try:
        own = own_addrs(run([cfg.ip, "-j", "addr"]))
    except ValueError:
        own = set()
    log_text = run([cfg.journalctl, "-u", "sshd", "--since", cfg.since,
                    "-o", "cat", "--no-pager"])
    seen = {}
    for m in FROM_RE.finditer(log_text):
        addr = m.group(1)
        if not is_trusted(addr, own):
            seen[addr] = seen.get(addr, 0) + 1
    return [f"SSH from outside the LAN/tailnet: {a} ×{n} — check router port-forwards"
            for a, n in sorted(seen.items())]


def assess(cfg, run, home_of, exists):
    return "\n".join(
        unmanaged_keys(cfg, home_of, exists, run)
        + unexpected_funnels(cfg, run)
        + external_ssh(cfg, run)
    )


def main(argv=None, env=None, run=None, home_of=None, exists=None, log=None):
    import os
    import pwd
    import subprocess
    import sys

    cfg = Config.from_env(env)
    # stdout is the alert body; logs go to stderr.
    log = log or logger(TAG, stream=lambda: sys.stderr)
    if run is None:
        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True,
                                  check=False).stdout
    if home_of is None:
        def home_of(user):
            try:
                return pwd.getpwnam(user).pw_dir
            except KeyError:
                return None
    exists = exists or os.path.exists

    body = assess(cfg, run, home_of, exists)
    if body:
        print(body)
    else:
        log("ok")
    return 0
