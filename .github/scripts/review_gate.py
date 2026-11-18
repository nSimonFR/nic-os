"""Deterministic half of the review gate (.github/workflows/review-gate.yml).

The `review-gate` status is the only merge requirement of ruleset `main` besides
the CI checks. It is green on the PR head when Nico approved that commit, or when
an agent PR is small, stays outside PROTECTED and CodeRabbit (.coderabbit.yaml
auto_approvals) approved that commit. Run from main, never from the PR head.
Prints a JSON decision: ok, reasons, head, label (needs-human,
auto-merge-eligible or null while CodeRabbit has not approved), state (success,
pending, or null: post nothing) and description.
PROTECTED is the only path list; a pattern that matches no file on main (a
move) refuses every agent PR until it is updated.

Usage: review_gate.py PR_JSON FILES_JSON REVIEWS_JSON
  PR_JSON      `gh api repos/{repo}/pulls/{n}`
  FILES_JSON   `gh api --paginate --slurp repos/{repo}/pulls/{n}/files`
  REVIEWS_JSON `gh api --paginate --slurp repos/{repo}/pulls/{n}/reviews`
"""

import fnmatch
import json
import pathlib
import subprocess
import sys

AUTHORS = {"nSimonFR-ai"}
JUDGE = "coderabbitai[bot]"
HUMAN = "nSimonFR"
# Renovate merges through its ruleset bypass and waits on every status it
# sees: a pending one would stop its automerge.
RENOVATE = "nic-os-renovate[bot]"
MAX_LINES = 150
MAX_FILES = 6

# The gate itself, supply chain, secrets, and what agents may do.
PROTECTED = [
    ".github/*",
    ".coderabbit.yaml",
    "AGENTS.md",
    "scripts/push-ai",
    "flake.nix",
    "flake.lock",
    "*secrets.nix",
    "*.age",
    "hosts/*/security/*",
    "home/dotfiles/claude-settings.json",
    "hosts/rpi5/agents/hermes/hermes.nix",
]


def protected(path):
    return any(fnmatch.fnmatch(path, pat) for pat in PROTECTED)


def stale(tracked):
    """Protected patterns that match nothing on main."""
    return [p for p in PROTECTED if not any(fnmatch.fnmatch(t, p) for t in tracked)]


def verdict(pr, files, tracked):
    reasons = [f"protected pattern {p} matches no file on main" for p in stale(tracked)]
    author = (pr.get("user") or {}).get("login")
    if author not in AUTHORS:
        reasons.append(f"author {author} is not an agent")
    if pr.get("draft"):
        reasons.append("draft")
    if (pr.get("base") or {}).get("ref") != "main":
        reasons.append("base is not main")
    if len(files) > MAX_FILES:
        reasons.append(f"{len(files)} files > {MAX_FILES}")
    lines = sum(f.get("additions", 0) + f.get("deletions", 0) for f in files)
    if lines > MAX_LINES:
        reasons.append(f"{lines} changed lines > {MAX_LINES}")
    for f in files:
        for path in {f["filename"], f.get("previous_filename") or f["filename"]}:
            if protected(path):
                reasons.append(f"protected path {path}")
    return {"ok": not reasons, "reasons": sorted(set(reasons))}


def approved(reviews, login, head):
    """`login`'s latest verdict (not a plain comment) approves `head`."""
    verdicts = [
        r
        for r in reviews
        if (r.get("user") or {}).get("login") == login and r.get("state") != "COMMENTED"
    ]
    if not verdicts:
        return False
    last = max(verdicts, key=lambda r: r.get("submitted_at") or "")
    return last.get("state") == "APPROVED" and last.get("commit_id") == head


def decide(pr, files, reviews, tracked):
    v = verdict(pr, files, tracked)
    head = (pr.get("head") or {}).get("sha", "")
    judged = approved(reviews, JUDGE, head)
    if approved(reviews, HUMAN, head):
        state, description = "success", "Nico approved this commit"
    elif v["ok"] and judged:
        state, description = "success", "CodeRabbit approved this commit"
    elif v["ok"]:
        state, description = "pending", "Waiting for CodeRabbit's approval, or Nico's"
    else:
        state, description = (
            "pending",
            "Needs Nico's approval (reasons in the gate run)",
        )
    renovate = (pr.get("user") or {}).get("login") == RENOVATE
    if renovate and state != "success":
        state = None
    label = (
        None
        if renovate
        else "needs-human"
        if not v["ok"]
        else ("auto-merge-eligible" if judged else None)
    )
    return {
        **v,
        "head": head,
        "label": label,
        "state": state,
        "description": description if state else "",
    }


def tracked_files(run=subprocess.run):
    root = pathlib.Path(__file__).resolve().parents[2]
    out = run(
        ["git", "-C", str(root), "ls-files"], capture_output=True, text=True, check=True
    )
    return out.stdout.splitlines()


def main(argv, tracked=None):
    pr = json.load(open(argv[1]))
    files = [f for page in json.load(open(argv[2])) for f in page]
    reviews = [r for page in json.load(open(argv[3])) for r in page]
    tracked = tracked_files() if tracked is None else tracked
    print(json.dumps(decide(pr, files, reviews, tracked)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
