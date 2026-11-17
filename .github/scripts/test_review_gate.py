import importlib.util
import pathlib

spec = importlib.util.spec_from_file_location(
    "review_gate", pathlib.Path(__file__).with_name("review_gate.py")
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

PR = {"user": {"login": "nSimonFR-ai"}, "draft": False, "base": {"ref": "main"}}


def f(name, add=1, rm=0, prev=None):
    d = {"filename": name, "additions": add, "deletions": rm}
    if prev:
        d["previous_filename"] = prev
    return d


def test_small_agent_change_passes():
    assert gate.verdict(PR, [f("hosts/rpi5/agents/mcp-bridges.nix", 3, 1)]) == {
        "ok": True,
        "reasons": [],
    }


def test_human_author_is_refused():
    pr = {**PR, "user": {"login": "nSimonFR"}}
    assert not gate.verdict(pr, [f("README.md")])["ok"]


def test_protected_paths_are_refused():
    for path in [
        ".github/workflows/review-gate.yml",
        ".github/scripts/review_gate.py",
        ".coderabbit.yaml",
        "flake.lock",
        "hosts/rpi5/secrets.nix",
        "hosts/rpi5/secrets/x.age",
        "hosts/rpi5/security/agent-vault.nix",
        "hosts/rpi5/agents/hermes/hermes.nix",
    ]:
        assert not gate.verdict(PR, [f(path)])["ok"], path


def test_a_rename_out_of_a_protected_path_is_refused():
    assert not gate.verdict(PR, [f("docs/x.md", prev="AGENTS.md")])["ok"]


def test_size_limits():
    assert not gate.verdict(PR, [f("a.nix", 100, 51)])["ok"]
    assert not gate.verdict(PR, [f(f"{i}.nix") for i in range(7)])["ok"]
    assert gate.verdict(PR, [f(f"{i}.nix", 25) for i in range(6)])["ok"]


def test_draft_and_other_base_are_refused():
    assert not gate.verdict({**PR, "draft": True}, [f("a.nix")])["ok"]
    assert not gate.verdict({**PR, "base": {"ref": "x"}}, [f("a.nix")])["ok"]
