import json

import pytest

from conftest import FakeResponse
from nicos_scripts.agent_vault import bootstrap as mod

SERVICES = [{"name": "linear", "host": "api.linear.app",
             "keys": ["LINEAR_KEY", "LINEAR_KEY_TRUSK"], "in": ["header"]}]

ROUTES = {
    ("GET", "/health"): (200, {}),
    ("POST", "/v1/auth/login"): (401, {"error": "bad"}),
    ("POST", "/v1/auth/register"): (201, {"token": "sess"}),
    ("PUT", "/v1/admin/settings"): (200, {}),
    ("POST", "/v1/credentials"): (200, {}),
    ("PUT", "/v1/vaults/default/services"): (200, {}),
    ("GET", "/discover"): (401, {}),
    ("POST", "/v1/agents"): (201, {"av_agent_token": "av_agt_new"}),
    ("GET", "/v1/mitm/ca.pem"): (200, "MITM\n"),
}


def server(routes):
    seen = {}

    def opener(req, timeout=None):
        key = (req.get_method(), req.full_url.split("http://av", 1)[1])
        seen[key] = json.loads(req.data) if req.data else None
        status, reply = routes[key]
        return FakeResponse((reply if isinstance(reply, str) else json.dumps(reply)).encode(), status)

    return opener, seen


@pytest.fixture
def cfg(tmp_path):
    (tmp_path / "out").mkdir()
    (tmp_path / "s.json").write_text(json.dumps(SERVICES))
    (tmp_path / "creds").write_text('# x\nLINEAR_KEY="lin-1"\nLINEAR_KEY_TRUSK=a=b\nHA_TOKEN=x\n')
    (tmp_path / "pw").write_text("hunter22\n")
    (tmp_path / "roots").write_text("ROOTS\n")
    return mod.Config(addr="http://av", admin_password_file=str(tmp_path / "pw"),
                      creds_file=str(tmp_path / "creds"), services_file=str(tmp_path / "s.json"),
                      out_dir=str(tmp_path / "out"), no_proxy=".ts.net",
                      system_ca_bundle=str(tmp_path / "roots"), dry_run=False)


def test_fresh_install(cfg):
    opener, seen = server(ROUTES)
    mod.run(cfg, opener=opener, sleep=lambda _: None)
    assert seen[("POST", "/v1/credentials")]["credentials"] == {"LINEAR_KEY": "lin-1", "LINEAR_KEY_TRUSK": "a=b"}
    assert seen[("PUT", "/v1/vaults/default/services")]["services"][0]["substitutions"][1] == {
        "key": "LINEAR_KEY_TRUSK", "placeholder": "__linear_key_trusk__", "in": ["header"]}
    env = (mod.Path(cfg.out_dir) / "proxy.env").read_text()
    assert "HTTPS_PROXY=http://av_agt_new:default@127.0.0.1:14322" in env
    assert "NO_PROXY=localhost,127.0.0.1,::1,.ts.net" in env
    assert "LINEAR_KEY=__linear_key__" in env and "lin-1" not in env
    assert (mod.Path(cfg.out_dir) / "ca-bundle.pem").read_text() == "ROOTS\nMITM\n"


def test_working_token_is_kept(cfg):
    (mod.Path(cfg.out_dir) / "agent-token").write_text("av_agt_old\n")
    opener, seen = server({**ROUTES, ("GET", "/discover"): (200, {})})
    mod.run(cfg, opener=opener, sleep=lambda _: None)
    assert ("POST", "/v1/agents") not in seen
    assert "av_agt_old:default@" in (mod.Path(cfg.out_dir) / "proxy.env").read_text()


def test_missing_credential_fails_before_any_call(cfg):
    mod.Path(cfg.creds_file).write_text("LINEAR_KEY=lin-1\n")
    opener, seen = server(ROUTES)
    with pytest.raises(RuntimeError, match="LINEAR_KEY_TRUSK"):
        mod.run(cfg, opener=opener)
    assert seen == {}


def test_attaching_service_reads_its_own_secret_and_routes_git(cfg, tmp_path):
    (tmp_path / "gh").write_text("ghx_real\n")
    (tmp_path / "user").write_text("x-access-token")
    mod.Path(cfg.services_file).write_text(json.dumps(SERVICES + [
        {"name": "github", "host": "github.com",
         "auth": {"type": "basic", "username": "GH_USER", "password": "GH_TOKEN_AI"}}]))
    cfg = mod.Config(**{**cfg.__dict__, "cred_files": f"GH_TOKEN_AI={tmp_path}/gh,GH_USER={tmp_path}/user"})
    opener, seen = server(ROUTES)
    mod.run(cfg, opener=opener, sleep=lambda _: None)
    assert seen[("POST", "/v1/credentials")]["credentials"]["GH_TOKEN_AI"] == "ghx_real"
    assert seen[("PUT", "/v1/vaults/default/services")]["services"][1] == {
        "name": "github", "host": "github.com",
        "auth": {"type": "basic", "username": "GH_USER", "password": "GH_TOKEN_AI"}}
    out = mod.Path(cfg.out_dir)
    assert "ghx_real" not in (out / "proxy.env").read_text() + (out / "gitconfig").read_text()
    assert "GH_TOKEN_AI" not in (out / "proxy.env").read_text()
    assert '[http "https://github.com/"]\n\tproxy = http://av_agt_new:default@127.0.0.1:14322\n' \
        in (out / "gitconfig").read_text()
    assert '[http "https://api.linear.app/"]' not in (out / "gitconfig").read_text()


def test_an_optional_cred_file_overrides_when_present_and_is_skipped_when_absent(cfg, tmp_path):
    (tmp_path / "ha").write_text("ha-from-file\n")
    present = mod.Config(**{**cfg.__dict__, "cred_files": f"HA_TOKEN=-{tmp_path}/ha"})
    assert mod.load_creds(present)["HA_TOKEN"] == "ha-from-file"
    absent = mod.Config(**{**cfg.__dict__, "cred_files": f"HA_TOKEN=-{tmp_path}/nope"})
    assert mod.load_creds(absent)["HA_TOKEN"] == "x"
