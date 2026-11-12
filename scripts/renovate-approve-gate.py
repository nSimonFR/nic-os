#!/usr/bin/env python3
"""Decide whether a PR may be auto-approved (.github/workflows/renovate-approve.yml).

Prints the head SHA to approve and exits 0 when the PR is eligible; prints
nothing and explains on stderr when it is not. Never trusts the PR's own
workflows or code: everything is read through the API, so a PR can only be
eligible by being a pure version/checksum bump of an allowlisted file.
"""

import json
import re
import subprocess
import sys

BOT = "nSimonFR-ai"
BRANCH_PREFIX = "renovate/"
# Only files whose every changed line is a pin the `hashes` check re-derives
# from upstream. Widening this widens what a compromised bot account can ship
# to the unattended rpi5 deploy.
ALLOWED_FILES = {"pkgs/agents/claude-code.nix"}
ALLOWED_LINE = re.compile(
    r'^[+-]\s+(version = "\d+\.\d+\.\d+";|checksum = "[0-9a-f]{64}";)$'
)


def gh_api(path):
    out = subprocess.run(
        ["gh", "api", "--paginate", path], check=True, capture_output=True, text=True
    ).stdout
    # --paginate on an array endpoint concatenates the pages as `][`.
    return json.loads(re.sub(r"\]\s*\[", ",", out))


def refusal(pr, files):
    """Why this PR must not be auto-approved, or None if it may be."""
    if pr["state"] != "open" or pr["draft"]:
        return "not an open, ready PR"
    if pr["base"]["ref"] != "main":
        return "base is not main"
    if (
        pr["head"]["repo"] is None
        or pr["head"]["repo"]["full_name"] != pr["base"]["repo"]["full_name"]
    ):
        return "head is not in this repository"
    if not pr["head"]["ref"].startswith(BRANCH_PREFIX):
        return f"branch is not {BRANCH_PREFIX}*"
    if pr["user"]["login"] != BOT:
        return f"author is not {BOT}"
    if not files:
        return "no changed files"
    for f in files:
        if f["filename"] not in ALLOWED_FILES or f["status"] != "modified":
            return f"{f['filename']} ({f['status']}) is not allowlisted"
        patch = f.get("patch")
        if not patch:
            return f"{f['filename']} has no inline patch"
        # The API patch starts at the first @@: no ---/+++ headers to skip, so
        # every +/- line is content, including one that begins with `--`.
        changed = [ln for ln in patch.splitlines() if ln.startswith(("+", "-"))]
        if not changed:
            return f"{f['filename']} has no changed lines"
        for ln in changed:
            if not ALLOWED_LINE.match(ln):
                return f"unexpected change in {f['filename']}: {ln[:80]}"
    return None


def main(argv, gh=gh_api):
    repo, number = argv
    pr = gh(f"repos/{repo}/pulls/{number}")
    files = gh(f"repos/{repo}/pulls/{number}/files")
    # A push between the two reads would pair old files with a new head.
    if gh(f"repos/{repo}/pulls/{number}")["head"]["sha"] != pr["head"]["sha"]:
        print("head moved while checking", file=sys.stderr)
        return 0
    why = refusal(pr, files)
    if why:
        print(f"not auto-approving: {why}", file=sys.stderr)
        return 0
    print(pr["head"]["sha"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
