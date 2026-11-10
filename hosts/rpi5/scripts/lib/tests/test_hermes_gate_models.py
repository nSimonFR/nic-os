import io
import json

from nicos_scripts.hermes import gate_models as gm


class Resp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def opener_for(*bodies):
    calls = []

    def opener(req, timeout=None):
        calls.append(req.full_url)
        body = bodies[min(len(calls), len(bodies)) - 1]
        if isinstance(body, Exception):
            raise body
        return Resp(json.dumps(body).encode())

    opener.calls = calls
    return opener


def hermes_config(tmp_path):
    p = tmp_path / "config.yaml"
    p.write_text(
        json.dumps(
            {
                "model": {"model": "gpt-6-luna"},
                "custom_providers": [
                    {
                        "name": "tiny-llm-gate",
                        "model": "gpt-6-luna",
                        "models": {"gpt-6-luna": {"context_length": 131072}},
                    }
                ],
            }
        )
    )
    return p


CATALOG = {"models": [{"slug": "gpt-6.1-sol"}, {"slug": "asale-gpt-6-luna"}]}


def cfg_for(path, wait=0):
    return gm.Config(hermes_config=str(path), wait_seconds=wait)


def test_replaces_models_keeping_the_default(tmp_path):
    path = hermes_config(tmp_path)
    gm.run(cfg_for(path), opener=opener_for(CATALOG))
    models = json.loads(path.read_text())["custom_providers"][0]["models"]
    assert list(models) == ["gpt-6.1-sol", "asale-gpt-6-luna", "gpt-6-luna"]
    assert models["gpt-6.1-sol"] == {"context_length": 131072}
    assert oct(path.stat().st_mode & 0o777) == "0o600"


def test_gate_down_keeps_the_baked_list(tmp_path):
    path = hermes_config(tmp_path)
    before = path.read_text()
    assert gm.run(cfg_for(path), opener=opener_for(OSError("refused"))) == 0
    assert path.read_text() == before


def test_retries_an_empty_catalog_until_it_fills(tmp_path):
    path = hermes_config(tmp_path)
    now = [0.0]
    op = opener_for({"models": []}, CATALOG)
    gm.run(
        cfg_for(path, wait=30),
        opener=op,
        sleep=lambda s: now.__setitem__(0, now[0] + s),
        clock=lambda: now[0],
    )
    assert len(op.calls) == 2
    assert "gpt-6.1-sol" in path.read_text()


def test_missing_provider_is_a_no_op(tmp_path):
    path = tmp_path / "config.yaml"
    path.write_text(json.dumps({"custom_providers": [{"name": "other"}]}))
    gm.run(cfg_for(path), opener=opener_for(CATALOG))
    assert "gpt-6.1-sol" not in path.read_text()


def test_config_from_env_reads_overrides():
    cfg = gm.Config.from_env({"HERMES_CONFIG": "/x/c.yaml", "WAIT_SECONDS": "5"})
    assert cfg.hermes_config == "/x/c.yaml" and cfg.wait_seconds == 5


def test_unchanged_list_does_not_rewrite(tmp_path):
    path = hermes_config(tmp_path)
    gm.run(cfg_for(path), opener=opener_for(CATALOG))
    before = path.stat().st_mtime_ns, path.stat().st_ino
    gm.run(cfg_for(path), opener=opener_for(CATALOG))
    assert (path.stat().st_mtime_ns, path.stat().st_ino) == before


def test_reordered_catalog_is_a_change(tmp_path):
    path = hermes_config(tmp_path)
    gm.run(cfg_for(path), opener=opener_for(CATALOG))
    flipped = {"models": list(reversed(CATALOG["models"]))}
    gm.run(cfg_for(path), opener=opener_for(flipped))
    models = json.loads(path.read_text())["custom_providers"][0]["models"]
    assert list(models)[:2] == ["asale-gpt-6-luna", "gpt-6.1-sol"]
