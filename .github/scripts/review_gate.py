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

CodeRabbit's approval counts only if it reached it alone: every thread it
opened was resolved by itself or Nico, no one but Nico asked it to approve or
resolve, and no outsider commented (the repo is public: anyone can talk
CodeRabbit into resolving a thread; agents author the PRs).

Usage: review_gate.py PR_JSON FILES_JSON REVIEWS_JSON COMMENTS_JSON THREADS_JSON
  PR_JSON       `gh api repos/{repo}/pulls/{n}`
  FILES_JSON    pages of files: `gh api --paginate compare/{base}...{head} --jq .files | jq -s .`
  REVIEWS_JSON  `gh api --paginate --slurp repos/{repo}/pulls/{n}/reviews`
  COMMENTS_JSON [{login, body}] of the PR's issue and review comments
  THREADS_JSON  GraphQL pullRequest.reviewThreads {pageInfo{hasNextPage},
                nodes{isResolved resolvedBy{login} comments(first:1){nodes{author{login}}}}}
"""

import fnmatch
import json
import re
import pathlib
import subprocess
import sys

AUTHORS = {"nSimonFR-ai"}
JUDGE = "coderabbitai[bot]"
HUMAN = "nSimonFR"
# Renovate merges through its ruleset bypass and waits on every status it
# sees: a pending one would stop its automerge.
RENOVATE = "nic-os-renovate[bot]"
# Who may resolve CodeRabbit's threads or send it commands. GraphQL names
# the bot `coderabbitai` as a comment author and `coderabbitai[bot]` as a resolver.
TRUSTED = {JUDGE, HUMAN}
# Who may comment on a PR at all for CodeRabbit's approval to count.
INSIDERS = TRUSTED | AUTHORS | {RENOVATE, "github-actions[bot]"}
# Broad on purpose (anywhere, any wording): a false positive only sends the PR to Nico.
COMMAND = re.compile(
    r"@coderabbit(ai)?\b.*\b(approve|resolve)\b", re.IGNORECASE | re.DOTALL
)
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


def tampered(reviews, comments, threads):
    """Why CodeRabbit's approval may not be its own; None if no reason."""
    if threads is None or comments is None:
        return ["CodeRabbit's threads or the comments could not be read"]
    reasons = []
    if (threads.get("pageInfo") or {}).get("hasNextPage"):
        reasons.append("more review threads than the gate reads")
    for t in threads.get("nodes") or []:
        first = ((t.get("comments") or {}).get("nodes") or [{}])[0]
        if (first.get("author") or {}).get("login") not in ("coderabbitai", JUDGE):
            continue
        by = (t.get("resolvedBy") or {}).get("login")
        if t.get("isResolved") and by not in TRUSTED:
            reasons.append(f"a CodeRabbit thread was resolved by {by}")
    said = list(comments) + [
        {"login": (r.get("user") or {}).get("login"), "body": r.get("body")}
        for r in reviews
    ]
    for c in said:
        login = c.get("login")
        if login not in INSIDERS:
            reasons.append(f"{login} commented: only Nico can clear it")
        elif login not in TRUSTED and COMMAND.search(c.get("body") or ""):
            reasons.append(f"{login} asked CodeRabbit to approve or resolve")
    return sorted(set(reasons)) or None


def decide(pr, files, reviews, tracked, comments=None, threads=None):
    v = verdict(pr, files, tracked)
    head = (pr.get("head") or {}).get("sha", "")
    judged = approved(reviews, JUDGE, head)
    why = tampered(reviews, comments, threads) if judged else None
    if why:
        v = {"ok": False, "reasons": sorted(set(v["reasons"] + why))}
        judged = False
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
    comments = json.load(open(argv[4])) if len(argv) > 4 else None
    threads = json.load(open(argv[5])) if len(argv) > 5 else None
    tracked = tracked_files() if tracked is None else tracked
    print(json.dumps(decide(pr, files, reviews, tracked, comments, threads)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
