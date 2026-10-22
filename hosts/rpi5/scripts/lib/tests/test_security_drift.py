"""See nicos_scripts/security/drift.py. Output shapes are copied from rpi5."""

import json

from nicos_scripts.security import drift

KEYGEN = (
    "256 SHA256:TRz3managed no comment (ED25519)\n"
    "256 SHA256:lqIv4iphone iPhone herdr-pair:iPhone (ED25519)\n"
)
FUNNEL = json.dumps({"AllowFunnel": {
    "rpi5.gate-mintaka.ts.net:443": True,
    "rpi5.gate-mintaka.ts.net:8443": True,
    "rpi5.gate-mintaka.ts.net:10000": True,
}})
SSHD = (
    "Accepted publickey for nsimon from 127.0.0.1 port 51234 ssh2: ED25519 SHA256:x\n"
    "Connection closed by 192.168.1.20 port 40000 [preauth]\n"
    "Accepted publickey for nsimon from 100.101.1.2 port 2222 ssh2\n"
    "Connection from fd7a:115c:a1e0::5 port 1 on fd7a:115c:a1e0::1 port 22\n"
)


def cfg(**kw):
    base = dict(allowed_keys=frozenset({"SHA256:TRz3managed"}),
                funnel_ports=frozenset({"443", "8443", "10000"}),
                users=("root", "nsimon"))
    base.update(kw)
    return drift.Config(**base)


OWN = json.dumps([{"ifname": "end0", "addr_info": [
    {"local": "192.168.1.68"}, {"local": "2a02:8424:5da0:e301:2ecf:67ff:fe01:a4e1"}]}])


def fake_run(keygen=KEYGEN, funnel=FUNNEL, sshd=SSHD, own=OWN):
    def run(cmd):
        if "addr" in cmd:
            return own
        if "-lf" in cmd:
            return keygen
        if "funnel" in cmd:
            return funnel
        if "sshd" in cmd:
            return sshd
        return ""
    return run


def homes(**h):
    return lambda user: h.get(user)


def check(c=None, run=None, home_of=None, exists=None):
    return drift.assess(c or cfg(), run or fake_run(),
                        home_of or homes(nsimon="/home/nsimon"),
                        exists or (lambda p: True))


def test_clean_state_is_silent():
    c = cfg(allowed_keys=frozenset({"SHA256:TRz3managed", "SHA256:lqIv4iphone"}))
    assert check(c) == ""


def test_unacknowledged_key_pages_with_its_fingerprint():
    body = check()
    assert "unmanaged SSH key for nsimon: SHA256:lqIv4iphone iPhone herdr-pair" in body
    assert "TRz3managed" not in body


def test_root_key_pages_too():
    body = check(home_of=homes(root="/root"))
    assert "for root: SHA256:lqIv4iphone" in body


def test_missing_file_or_deleted_user_is_silent():
    assert check(exists=lambda p: False) == ""
    assert check(home_of=homes()) == ""


def test_extra_funnel_pages():
    funnel = json.dumps({"AllowFunnel": {"h:443": True, "h:3960": True, "h:8443": False}})
    body = check(cfg(allowed_keys=frozenset({"SHA256:TRz3managed", "SHA256:lqIv4iphone"})),
                 run=fake_run(funnel=funnel))
    assert body.startswith("unexpected funnel on port 3960")
    assert "8443" not in body.split("(")[0]


def test_no_funnels_at_all_is_silent():
    assert drift.funnel_ports("{}") == set()
    assert drift.funnel_ports('{"AllowFunnel": null}') == set()


def test_unparseable_funnel_status_pages():
    body = check(run=fake_run(funnel="not json", keygen=""))
    assert "could not parse" in body


def test_lan_and_tailnet_ssh_are_silent():
    assert drift.external_ssh(cfg(), fake_run()) == []


def test_own_global_ipv6_is_silent():
    sshd = "Connection closed by 2a02:8424:5da0:e301:2ecf:67ff:fe01:a4e1 port 1 [preauth]\n"
    assert drift.external_ssh(cfg(), fake_run(sshd=sshd)) == []


def test_public_ssh_source_pages_once_per_address():
    sshd = SSHD + (
        "Invalid user admin from 203.0.113.7 port 5555\n"
        "Failed password for root from 203.0.113.7 port 5556 ssh2\n"
        "Connection closed by 2001:db8::1 port 9 [preauth]\n"
    )
    lines = drift.external_ssh(cfg(), fake_run(sshd=sshd))
    assert lines == [
        "SSH from outside the LAN/tailnet: 2001:db8::1 ×1 — check router port-forwards",
        "SSH from outside the LAN/tailnet: 203.0.113.7 ×2 — check router port-forwards",
    ]


def test_from_env_parses_word_lists():
    c = drift.Config.from_env({"FUNNEL_PORTS": "443 8443", "SSH_USERS": "root nsimon",
                               "ALLOWED_KEY_FINGERPRINTS": "SHA256:a SHA256:b"})
    assert c.funnel_ports == {"443", "8443"}
    assert c.users == ("root", "nsimon")
    assert c.allowed_keys == {"SHA256:a", "SHA256:b"}


def test_from_env_defaults_are_strict():
    c = drift.Config.from_env({})
    assert c.allowed_keys == frozenset()
    assert c.funnel_ports == frozenset()


def test_main_prints_only_the_body(capsys):
    drift.main(env={"SSH_USERS": "nsimon", "FUNNEL_PORTS": "443 8443 10000"},
               run=fake_run(), home_of=homes(nsimon="/home/nsimon"),
               exists=lambda p: True, log=lambda m: None)
    out = capsys.readouterr().out
    assert out.count("unmanaged SSH key") == 2
