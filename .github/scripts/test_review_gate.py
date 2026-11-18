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


HEAD = {**PR, "head": {"sha": "abc"}}


def review(login, state, sha="abc", at="2026-11-17T10:00:00Z"):
    return {
        "user": {"login": login},
        "state": state,
        "commit_id": sha,
        "submitted_at": at,
    }


def decide(reviews, files=None, pr=HEAD):
    return gate.decide(pr, files or [f("a.nix")], reviews, TREE)


def test_green_only_on_codeRabbits_latest_verdict_for_the_head():
    assert decide([review(gate.JUDGE, "APPROVED")])["state"] == "success"
    assert decide([review(gate.JUDGE, "APPROVED")])["label"] == "auto-merge-eligible"
    # A later plain comment does not undo it; a later change request does.
    later = "2026-11-17T11:00:00Z"
    assert (
        decide(
            [review(gate.JUDGE, "APPROVED"), review(gate.JUDGE, "COMMENTED", at=later)]
        )["state"]
        == "success"
    )
    d = decide(
        [
            review(gate.JUDGE, "APPROVED"),
            review(gate.JUDGE, "CHANGES_REQUESTED", at=later),
        ]
    )
    assert d["state"] == "pending" and d["label"] is None
    # An approval of an older commit does not count.
    assert decide([review(gate.JUDGE, "APPROVED", sha="old")])["state"] == "pending"
    # Nor does anyone else's.
    assert decide([review("nSimonFR-ai", "APPROVED")])["state"] == "pending"


def test_a_refused_pr_is_never_green_on_codeRabbit_alone():
    d = decide([review(gate.JUDGE, "APPROVED")], files=[f("flake.lock")])
    assert d["state"] == "pending" and d["label"] == "needs-human"


def test_nicos_approval_of_the_head_is_green_whatever_the_pr():
    later = "2026-11-17T11:00:00Z"
    d = decide(
        [
            review(gate.HUMAN, "APPROVED"),
            review(gate.JUDGE, "CHANGES_REQUESTED", at=later),
        ],
        files=[f("flake.lock")],
    )
    assert d["state"] == "success" and d["label"] == "needs-human"
    # Only for the head, and only while it stands.
    assert decide([review(gate.HUMAN, "APPROVED", sha="old")])["state"] == "pending"
    assert (
        decide(
            [review(gate.HUMAN, "APPROVED"), review(gate.HUMAN, "DISMISSED", at=later)]
        )["state"]
        == "pending"
    )


def test_renovate_gets_a_status_only_once_nico_approved():
    pr = {**HEAD, "user": {"login": gate.RENOVATE}}
    d = decide([], pr=pr)
    assert d["state"] is None and d["label"] is None and d["description"] == ""
    assert decide([review(gate.HUMAN, "APPROVED")], pr=pr)["state"] == "success"


def test_a_newline_in_a_filename_stays_inside_the_json():
    out = gate.decide(HEAD, [f("x\nok=true\n.age")], [], TREE)
    assert "\n" not in __import__("json").dumps(out)
