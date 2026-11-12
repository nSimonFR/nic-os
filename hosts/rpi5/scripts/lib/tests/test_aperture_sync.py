import io
import json

from nicos_scripts.llm import aperture_sync as ap


class Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


BASE = {
    "providers": {
        "rpi5-gate": {"models": ["gemma4:e4b", "openai/gpt-6-luna"]},
        "rpi5-gate-anthropic": {"models": ["claude-opus-5-5"]},
    },
    "exporters": {"s3": {"access_key_id": "__X__", "access_secret": "__X__"}},
}
GATE = {
    "data": [
        {"id": "gpt-6.1-terra"},
        {"id": "gemma4:e4b"},
        {"id": "codex/gpt-6.1-terra"},
    ]
}


class Aperture:
    """Fake gate + Aperture API, recording PUTs."""

    def __init__(self, held=None, gate=GATE, put_result=None, claude=None):
        self.held = held
        self.claude = claude or {"data": [{"id": "claude-opus-6"}]}
        self.gate = gate
        self.puts = []
        self.put_result = put_result or {"success": True, "hash": "h2"}

    def __call__(self, req, timeout=None):
        url = req.full_url
        if "api.anthropic.com" in url:
            self.anthropic_auth = req.get_header("Authorization")
            if isinstance(self.claude, Exception):
                raise self.claude
            return Resp(json.dumps(self.claude).encode())
        if url.endswith("/v1/models"):
            if isinstance(self.gate, Exception):
                raise self.gate
            return Resp(json.dumps(self.gate).encode())
        if req.get_method() == "PUT":
            self.puts.append(json.loads(req.data))
            return Resp(json.dumps(self.put_result).encode())
        body = {"config": json.dumps(self.held) if self.held else "", "hash": "h1"}
        return Resp(json.dumps(body).encode())


def cfg_for(tmp_path, apply=True):
    p = tmp_path / "base.json"
    p.write_text(json.dumps(BASE))
    return ap.Config(
        aperture_url="http://ap",
        base_config=str(p),
        s3_key="K",
        s3_secret="S",
        apply=apply,
    )


def test_merges_gate_ids_and_pushes_with_hash(tmp_path):
    fake = Aperture(held={"old": True})
    assert ap.run(cfg_for(tmp_path), opener=fake, sleep=lambda s: None) == 0
    (put,) = fake.puts
    assert put["hash"] == "h1"
    sent = json.loads(put["config"])
    assert sent["providers"]["rpi5-gate"]["models"] == [
        "gemma4:e4b",
        "gpt-6.1-terra",
        "openai/gpt-6-luna",
    ]
    assert sent["providers"]["rpi5-gate-anthropic"]["models"] == ["claude-opus-5-5"]
    assert sent["exporters"]["s3"] == {"access_key_id": "K", "access_secret": "S"}


def test_no_put_when_aperture_already_matches(tmp_path):
    cfg = cfg_for(tmp_path)
    want = ap.desired(BASE, ap.gate_ids(GATE), cfg)
    fake = Aperture(held=want)
    assert ap.run(cfg, opener=fake) == 0
    assert fake.puts == []


def test_gate_down_leaves_aperture_alone(tmp_path):
    fake = Aperture(held={"old": True}, gate=OSError("refused"))
    assert ap.run(cfg_for(tmp_path), opener=fake) == 0
    assert fake.puts == []


def test_dry_run_never_writes(tmp_path):
    fake = Aperture(held={"old": True})
    assert ap.run(cfg_for(tmp_path, apply=False), opener=fake) == 0
    assert fake.puts == []


def test_rejection_retries_then_fails(tmp_path):
    fake = Aperture(
        held={"old": True}, put_result={"success": False, "error": {"message": "no"}}
    )
    assert ap.run(cfg_for(tmp_path), opener=fake, sleep=lambda s: None, attempts=3) == 1
    assert len(fake.puts) == 3


def test_apply_is_off_without_env():
    assert ap.Config.from_env({}).apply is False
    assert ap.Config.from_env({"APERTURE_APPLY": "1"}).apply is True


def test_aperture_rewritten_apikey_still_counts_as_unchanged(tmp_path):
    cfg = cfg_for(tmp_path)
    base = json.loads(json.dumps(BASE))
    base["providers"]["rpi5-gate"]["apikey"] = "unused"
    (tmp_path / "base.json").write_text(json.dumps(base))
    held = ap.desired(base, ap.gate_ids(GATE), cfg)
    held["providers"]["rpi5-gate"]["apikey"] = "keyid:p:rpi5-gate:unused"
    held["providers"]["rpi5-gate"]["models"].reverse()
    held["exporters"]["s3"]["access_secret"] = "keyid:s3:access_secret"
    fake = Aperture(held=held)
    assert ap.run(cfg, opener=fake) == 0
    assert fake.puts == []


def test_merges_anthropic_ids_read_with_the_oauth_token(tmp_path):
    tok = tmp_path / "token"
    tok.write_text("oauth-tok\n")
    cfg = ap.Config(**{**cfg_for(tmp_path).__dict__, "anthropic_token_file": str(tok)})
    fake = Aperture(held={"old": True})
    assert ap.run(cfg, opener=fake) == 0
    sent = json.loads(fake.puts[0]["config"])
    assert sent["providers"]["rpi5-gate-anthropic"]["models"] == [
        "claude-opus-5-5",
        "claude-opus-6",
    ]
    assert fake.anthropic_auth == "Bearer oauth-tok"


def test_anthropic_down_leaves_aperture_alone(tmp_path):
    tok = tmp_path / "token"
    tok.write_text("t")
    cfg = ap.Config(**{**cfg_for(tmp_path).__dict__, "anthropic_token_file": str(tok)})
    fake = Aperture(held={"old": True}, claude=OSError("401"))
    assert ap.run(cfg, opener=fake) == 0
    assert fake.puts == []


CONNECTORS = {
    "servers": {
        "notes": {"protocol": "mcp", "url": "https://h:3980/mcp"},
        "sure": {
            "protocol": "mcp",
            "url": "https://h:3850/sure/mcp",
            "auth": {"type": "bearer_token", "secret": "env:MCP_API_TOKEN"},
            "send_caller_identity": True,
        },
    }
}


def connector_cfg(tmp_path, secrets):
    cfg = ap.Config(**{**cfg_for(tmp_path).__dict__, "connector_secrets": secrets})
    base = {**BASE, "connectors": CONNECTORS}
    (tmp_path / "base.json").write_text(json.dumps(base))
    return base, cfg


def test_connector_secret_filled_from_env(tmp_path):
    base, cfg = connector_cfg(tmp_path, {"MCP_API_TOKEN": "tok"})
    fake = Aperture(held={"old": True})
    assert ap.run(cfg, opener=fake) == 0
    servers = json.loads(fake.puts[0]["config"])["connectors"]["servers"]
    assert servers["sure"]["auth"]["secret"] == "tok"
    assert (
        base["connectors"]["servers"]["sure"]["auth"]["secret"] == "env:MCP_API_TOKEN"
    )


def test_connector_without_its_secret_is_left_out(tmp_path):
    _, cfg = connector_cfg(tmp_path, {"MCP_API_TOKEN": ""})
    fake = Aperture(held={"old": True})
    assert ap.run(cfg, opener=fake) == 0
    servers = json.loads(fake.puts[0]["config"])["connectors"]["servers"]
    assert sorted(servers) == ["notes"]


def test_aperture_rewritten_connector_still_counts_as_unchanged(tmp_path):
    base, cfg = connector_cfg(tmp_path, {"MCP_API_TOKEN": "tok"})
    held = ap.desired(base, ap.gate_ids(GATE), cfg)
    for server in held["connectors"]["servers"].values():
        server["provider"] = "Custom"
    held["connectors"]["servers"]["sure"]["auth"]["secret"] = "keyid:c:sure"
    fake = Aperture(held=held)
    assert ap.run(cfg, opener=fake) == 0
    assert fake.puts == []


def test_connector_secrets_read_only_by_name():
    env = {"APERTURE_CONNECTOR_SECRETS": "A B", "A": "1", "C": "3"}
    assert ap.Config.from_env(env).connector_secrets == {"A": "1", "B": ""}
