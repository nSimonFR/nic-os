import json

import pytest

from conftest import FakeResponse
from nicos_scripts.agent_vault import bootstrap as mod

SERVICES = [
    {"name": "tavily", "host": "api.tavily.com", "keys": ["TAVILY_API_KEY"], "in": ["header", "body"]},
    {"name": "linear", "host": "api.linear.app", "keys": ["LINEAR_KEY", "LINEAR_KEY_TRUSK"], "in": ["header"]},
]


class Server:
    """Routes (method, path) to canned replies and records the bodies it saw."""

    def __init__(self, routes):
        self.routes = routes
        self.seen = []

    def __call__(self, req, timeout=None):
        path = req.full_url.split("://", 1)[1].split("/", 1)[1]
        key = (req.get_method(), "/" + path)
        body = json.loads(req.data) if req.data else None
        self.seen.append((key, body, dict(req.header_items())))
        status, reply = self.routes[key](req) if callable(self.routes.get(key)) else self.routes[key]
        data = reply.encode() if isinstance(reply, str) else json.dumps(reply).encode()
        return FakeResponse(data, status)

    def calls(self, method, path):
        return [s for s in self.seen if s[0] == (method, path)]


def routes(over=None):
    base = {
        ("GET", "/health"): (200, {"status": "ok"}),
        ("POST", "/v1/auth/login"): (200, {"token": "sess"}),
        ("PUT", "/v1/admin/settings"): (200, {}),
        ("POST", "/v1/credentials"): (200, {}),
        ("PUT", "/v1/vaults/default/services"): (200, {}),
        ("GET", "/discover"): (401, {"error": "nope"}),
        ("GET", "/v1/agents/hermes"): (404, {"error": "Agent not found"}),
        ("POST", "/v1/agents"): (201, {"av_agent_token": "av_agt_new"}),
        ("POST", "/v1/agents/hermes/rotate"): (200, {"av_agent_token": "av_agt_rot"}),
        ("GET", "/v1/mitm/ca.pem"): (200, "-----BEGIN CERTIFICATE-----\nMITM\n"),
    }
    base.update(over or {})
    return base


@pytest.fixture
def setup(tmp_path):
    (tmp_path / "out").mkdir()
    (tmp_path / "services.json").write_text(json.dumps(SERVICES))
    (tmp_path / "creds.env").write_text(
        "# agent env\nTAVILY_API_KEY=tvly-1\nLINEAR_KEY=lin-1\nLINEAR_KEY_TRUSK=lin=2\nHA_TOKEN=x\n"
    )
    (tmp_path / "pw").write_text("hunter22\n")
    (tmp_path / "roots.pem").write_text("SYSTEM ROOTS\n")

    def cfg(**kw):
        return mod.Config(
            admin_email="admin@agent-vault.local",
            admin_password_file=str(tmp_path / "pw"),
            creds_file=str(tmp_path / "creds.env"),
            services_file=str(tmp_path / "services.json"),
            out_dir=str(tmp_path / "out"),
            no_proxy="api.telegram.org",
            system_ca_bundle=str(tmp_path / "roots.pem"),
            dry_run=kw.pop("dry_run", False),
            **kw,
        )

    return tmp_path, cfg


def run(cfg, server, ran=None):
    def run_cmd(argv, check):
        (ran if ran is not None else []).append(argv)
        return type("R", (), {"returncode": 0})()

    return mod.run(cfg, mod.Api("http://av", opener=server), sleep=lambda _: None, run_cmd=run_cmd)


def test_config_defaults_to_dry_run():
    assert mod.Config.from_env({}).dry_run is True
    assert mod.Config.from_env({"AGENT_VAULT_BOOTSTRAP_APPLY": "1"}).dry_run is False


def test_parse_env_file_keeps_equals_in_values():
    assert mod.parse_env_file("A=1\n# c\n\nB=x=y\nnoeq\n") == {"A": "1", "B": "x=y"}


def test_services_payload_is_passthrough_with_scoped_substitutions():
    linear = mod.services_payload(SERVICES)[1]
    assert linear["auth"] == {"type": "passthrough"}
    assert linear["substitutions"] == [
        {"key": "LINEAR_KEY", "placeholder": "__linear_key__", "in": ["header"]},
        {"key": "LINEAR_KEY_TRUSK", "placeholder": "__linear_key_trusk__", "in": ["header"]},
    ]


def test_dry_run_touches_nothing(setup):
    tmp, cfg = setup
    server = Server({})
    assert run(cfg(dry_run=True), server) == 0
    assert server.seen == []
    assert list((tmp / "out").iterdir()) == []


def test_missing_credential_fails_before_any_call(setup):
    tmp, cfg = setup
    (tmp / "creds.env").write_text("TAVILY_API_KEY=tvly-1\n")
    server = Server({})
    with pytest.raises(RuntimeError, match="LINEAR_KEY, LINEAR_KEY_TRUSK"):
        run(cfg(), server)
    assert server.seen == []


def test_fresh_install_registers_owner_and_mints_agent(setup):
    tmp, cfg = setup
    server = Server(routes({
        ("POST", "/v1/auth/login"): (401, {"error": "Invalid email or password"}),
        ("POST", "/v1/auth/register"): (201, {"token": "sess"}),
    }))
    assert run(cfg(), server) == 0

    creds = server.calls("POST", "/v1/credentials")[0][1]
    assert creds == {"vault": "default", "credentials": {
        "LINEAR_KEY": "lin-1", "LINEAR_KEY_TRUSK": "lin=2", "TAVILY_API_KEY": "tvly-1"}}
    assert "HA_TOKEN" not in json.dumps(server.seen)
    assert server.calls("PUT", "/v1/admin/settings")[0][1] == {"invite_only": True}
    assert server.calls("POST", "/v1/agents")[0][1]["vaults"] == [
        {"vault_name": "default", "vault_role": "proxy"}]

    out = tmp / "out"
    assert (out / "agent-token").read_text() == "av_agt_new\n"
    assert (out / "ca-bundle.pem").read_text() == "SYSTEM ROOTS\n-----BEGIN CERTIFICATE-----\nMITM\n"
    env = mod.parse_env_file((out / "proxy.env").read_text())
    assert env["HTTPS_PROXY"] == "http://av_agt_new:default@127.0.0.1:14322"
    assert env["NO_PROXY"] == "localhost,127.0.0.1,::1,api.telegram.org"
    assert env["SSL_CERT_FILE"] == str(out / "ca-bundle.pem")
    assert env["LINEAR_KEY_TRUSK"] == "__linear_key_trusk__"
    assert "tvly-1" not in (out / "proxy.env").read_text()
    assert oct((out / "proxy.env").stat().st_mode & 0o777) == "0o400"


def test_working_token_is_kept(setup):
    tmp, cfg = setup
    (tmp / "out" / "agent-token").write_text("av_agt_old\n")
    server = Server(routes({("GET", "/discover"): (200, {})}))
    ran = []
    run(cfg(on_token_change="restart hermes"), server, ran)
    assert ran == []
    assert server.calls("GET", "/discover")[0][2]["X-vault"] == "default"
    assert not server.calls("POST", "/v1/agents") and not server.calls("POST", "/v1/agents/hermes/rotate")
    assert "av_agt_old:default@" in (tmp / "out" / "proxy.env").read_text()


def test_dead_token_of_existing_agent_is_rotated(setup):
    tmp, cfg = setup
    (tmp / "out" / "agent-token").write_text("av_agt_revoked\n")
    server = Server(routes({("GET", "/v1/agents/hermes"): (200, {"name": "hermes"})}))
    ran = []
    run(cfg(on_token_change="systemctl --user -M nsimon@ restart hermes"), server, ran)
    assert (tmp / "out" / "agent-token").read_text() == "av_agt_rot\n"
    assert ran == [["systemctl", "--user", "-M", "nsimon@", "restart", "hermes"]]


def test_wrong_owner_password_is_fatal(setup):
    _, cfg = setup
    server = Server(routes({
        ("POST", "/v1/auth/login"): (401, {"error": "Invalid email or password"}),
        ("POST", "/v1/auth/register"): (201, {"requires_verification": True}),
    }))
    with pytest.raises(RuntimeError, match="cannot log in or register"):
        run(cfg(), server)


def test_rejected_services_are_fatal(setup):
    _, cfg = setup
    server = Server(routes({("PUT", "/v1/vaults/default/services"): (400, {"error": "bad"})}))
    with pytest.raises(RuntimeError, match="services failed"):
        run(cfg(), server)
