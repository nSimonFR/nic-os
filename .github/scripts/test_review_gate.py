import importlib.util
import pathlib

spec = importlib.util.spec_from_file_location(
    "review_gate", pathlib.Path(__file__).with_name("review_gate.py")
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

PR = {"user": {"login": "nSimonFR-ai"}, "draft": False, "base": {"ref": "main"}}
# One file per protected pattern: a tree with nothing stale.
TREE = [
    ".github/workflows/review-gate.yml",
    ".coderabbit.yaml",
    "AGENTS.md",
    "scripts/push-ai",
    "flake.nix",
    "flake.lock",
    "hosts/rpi5/secrets.nix",
    "hosts/rpi5/secrets/x.age",
    "hosts/rpi5/security/agent-vault.nix",
    "home/dotfiles/claude-settings.json",
    "hosts/rpi5/agents/hermes/hermes.nix",
]


def verdict(pr, files, tracked=TREE):
    return gate.verdict(pr, files, tracked)


def f(name, add=1, rm=0, prev=None):
    d = {"filename": name, "additions": add, "deletions": rm}
    if prev:
        d["previous_filename"] = prev
    return d


def test_small_agent_change_passes():
    assert verdict(PR, [f("hosts/rpi5/agents/mcp-bridges.nix", 3, 1)]) == {
        "ok": True,
        "reasons": [],
    }


def test_human_author_is_refused():
    pr = {**PR, "user": {"login": "nSimonFR"}}
    assert not verdict(pr, [f("README.md")])["ok"]


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
        assert not verdict(PR, [f(path)])["ok"], path


def test_a_rename_out_of_a_protected_path_is_refused():
    assert not verdict(PR, [f("docs/x.md", prev="AGENTS.md")])["ok"]


def test_size_limits():
    assert not verdict(PR, [f("a.nix", 100, 51)])["ok"]
    assert not verdict(PR, [f(f"{i}.nix") for i in range(7)])["ok"]
    assert verdict(PR, [f(f"{i}.nix", 25) for i in range(6)])["ok"]


def test_draft_and_other_base_are_refused():
    assert not verdict({**PR, "draft": True}, [f("a.nix")])["ok"]
    assert not verdict({**PR, "base": {"ref": "x"}}, [f("a.nix")])["ok"]


def test_a_moved_protected_file_refuses_every_pr():
    moved = [t for t in TREE if not t.endswith("hermes.nix")] + [
        "hosts/rpi5/agents/hermes/default.nix"
    ]
    v = verdict(PR, [f("README.md")], moved)
    assert v == {
        "ok": False,
        "reasons": [
            "protected pattern hosts/rpi5/agents/hermes/hermes.nix matches no file on main"
        ],
    }


def test_the_real_tree_has_no_stale_pattern():
    assert gate.stale(gate.tracked_files()) == []
