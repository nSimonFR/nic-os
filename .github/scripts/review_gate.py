"""Deterministic half of the review gate (.github/workflows/review-gate.yml).

CodeRabbit judges risk and approves (.coderabbit.yaml auto_approvals); this only
refuses what must always reach a human, whatever an LLM says. Run from main,
never from the PR head. Prints a JSON verdict: {"ok": bool, "reasons": [...]}.

Usage: review_gate.py PR_JSON FILES_JSON
  PR_JSON    `gh api repos/{repo}/pulls/{n}`
  FILES_JSON `gh api --paginate --slurp repos/{repo}/pulls/{n}/files`
"""

import fnmatch
import json
import sys

AUTHORS = {"nSimonFR-ai"}
MAX_LINES = 150
MAX_FILES = 6

# The gate itself, supply chain, secrets, and what agents may do.
PROTECTED = [
    ".github/*",
    ".coderabbit.yaml",
    "AGENTS.md",
    "CLAUDE.md",
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


def verdict(pr, files):
    reasons = []
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


def main(argv):
    pr = json.load(open(argv[1]))
    pages = json.load(open(argv[2]))
    files = [f for page in pages for f in page]
    print(json.dumps(verdict(pr, files)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
