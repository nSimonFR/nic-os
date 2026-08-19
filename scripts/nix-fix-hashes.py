#!/usr/bin/env python3
"""Recompute the Nix fixed-output hashes Renovate cannot.

renovate.json's regex manager bumps `version` in pkgs/**, and Renovate has no
way to recompute a fixed-output hash — so the `hash` / `npmDepsHash` beside that
version keep pointing at the previous release. The repo knew this and documented
it (renovate.json's prBodyNotes: "Does not build as-is"), but nothing enforced
it: .github/workflows/nix.yml evaluates `system.build.toplevel.drvPath`, and
evaluation never realises a fixed-output derivation. A stale hash is therefore
invisible to eval, so those PRs went green, and on 2026-08-19 three of them
merged in a row (affine-mcp-server 3.2.2, ha-intratone 0.9.3, ha-linky 1.8.0),
each with two dead hashes, leaving main unbuildable: `nixos-rebuild` died on
`hash mismatch in fixed-output derivation` before it could switch.

This script closes that hole from both ends: checking (the default) is the CI gate
that turns such a PR red, and `--write` is the one command that finishes it.

It works from what the package file already states — owner, repo, rev — rather
than from a flake attribute, because most files under pkgs/ are callPackage'd at
their single use site (see pkgs/overlay.nix) and have no `packages.<system>`
output to build. It also doesn't build anything: a `hash` pin covers exactly the
unpacked tag tarball, and an `npmDepsHash` pin exactly the closure of a
package-lock.json, so fetching those two is enough. That keeps the gate at a few
seconds per package on any architecture — which matters, since the packages this
guards are aarch64 and the cheap runners are not.

Usage:
    scripts/nix-fix-hashes.py                  # check every package under pkgs/
    scripts/nix-fix-hashes.py --write FILE...  # rewrite the drifted hashes
    scripts/nix-fix-hashes.py --strict         # audit: also fail the unverifiable
Exit status is 1 when a pinned hash disagrees with the fetched artifact, and —
under --strict only — when a package could not be verified here at all.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

# `${version}`-style interpolations that appear inside a `rev`. Resolved from
# plain `name = "value";` bindings in the same file, which is all these fetchers
# use in practice (`rev = "v${version}"`, `rev = version`, `repo = pname`).
INTERP = re.compile(r"\$\{([a-zA-Z_][\w.-]*)\}")

BINDING = re.compile(r'^\s*(?P<key>[a-zA-Z_][\w-]*)\s*=\s*"(?P<val>[^"]*)"\s*;', re.M)
BARE_BINDING = re.compile(r"^\s*(?P<key>[a-zA-Z_][\w-]*)\s*=\s*(?P<val>[a-zA-Z_][\w.-]*)\s*;", re.M)
HASH_LINE = re.compile(r'(?P<key>\bhash|\bnpmDepsHash)\s*=\s*"(?P<val>[^"]*)"')

# Hashes this script cannot derive from a fetch: they are the output of a build
# (Go module vendoring, a pnpm store, a Cargo vendor tree). Their presence does
# NOT stop the file being checked — blogwatcher pins a `vendorHash` and still
# shipped a wrong `src.hash` on 2026-08-19, so bailing on the whole file would
# skip exactly the hash this can verify. They are reported alongside the result.
UNVERIFIABLE = ("vendorHash", "cargoHash", "pnpmDepsHash", "cargoDeps")


class Problem(Exception):
    """A file this script cannot speak for. Never silently skipped."""


@dataclass
class Package:
    path: Path
    owner: str
    repo: str
    rev: str
    pinned: dict[str, str] = field(default_factory=dict)
    actual: dict[str, str] = field(default_factory=dict)
    unverifiable: list[str] = field(default_factory=list)

    @property
    def tarball(self) -> str:
        # GitHub's /archive/<ref> resolves tags and commits alike, and is the same
        # endpoint fetchFromGitHub itself fetches through — so the NAR hash of the
        # unpacked result is exactly what the `hash` pin holds.
        return f"https://github.com/{self.owner}/{self.repo}/archive/{self.rev}.tar.gz"

    @property
    def drift(self) -> dict[str, tuple[str, str]]:
        return {
            key: (self.pinned[key], self.actual[key])
            for key in self.pinned
            if key in self.actual and self.pinned[key] != self.actual[key]
        }


def run(*cmd: str) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise Problem(f"{cmd[0]} failed: {(proc.stderr or proc.stdout).strip().splitlines()[-1:]}")
    return proc.stdout.strip()


def to_sri(value: str) -> str:
    """base32 (nix-prefetch-url's output) → SRI (what a Nix file pins)."""
    if value.startswith("sha256-"):
        return value
    return run("nix", "hash", "convert", "--hash-algo", "sha256", "--to", "sri", value)


def resolve(template: str, bindings: dict[str, str]) -> str:
    def sub(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in bindings:
            raise Problem(f"cannot resolve ${{{name}}} in {template!r}")
        return bindings[name]

    return INTERP.sub(sub, template)


def parse(path: Path) -> Package:
    text = path.read_text()

    bindings = {m["key"]: m["val"] for m in BINDING.finditer(text)}
    # `rev = version;` — an unquoted reference to another binding.
    for match in BARE_BINDING.finditer(text):
        if match["key"] not in bindings and match["val"] in bindings:
            bindings[match["key"]] = bindings[match["val"]]

    unverifiable = [key for key in UNVERIFIABLE if re.search(rf"\b{key}\s*=", text)]
    if "fetchFromGitHub" not in text:
        raise Problem("no fetchFromGitHub — nothing this script knows how to fetch")

    pinned = {m["key"]: m["val"] for m in HASH_LINE.finditer(text)}
    if "hash" not in pinned:
        raise Problem("no `hash =` to check")
    if len(HASH_LINE.findall(text)) != len(pinned):
        raise Problem("more than one fetcher in the file — recompute this one by hand")

    for key in ("owner", "repo", "rev"):
        if key not in bindings:
            raise Problem(f"no `{key}` binding found")

    return Package(
        path=path,
        owner=resolve(bindings["owner"], bindings),
        repo=resolve(bindings["repo"], bindings),
        rev=resolve(bindings["rev"], bindings),
        pinned=pinned,
        unverifiable=unverifiable,
    )


def fetch(pkg: Package) -> None:
    # --print-path prints the hash, then the store path of the unpacked tree.
    out = run("nix-prefetch-url", "--unpack", "--print-path", pkg.tarball).splitlines()
    if len(out) < 2:
        raise Problem(f"unexpected nix-prefetch-url output for {pkg.tarball}")
    pkg.actual["hash"] = to_sri(out[-2])
    src = Path(out[-1])

    if "npmDepsHash" not in pkg.pinned:
        return
    lock = src / "package-lock.json"
    if not lock.is_file():
        raise Problem("pins npmDepsHash but the tag has no package-lock.json")
    pkg.actual["npmDepsHash"] = run(
        "nix", "run", "nixpkgs#prefetch-npm-deps", "--", str(lock)
    ).splitlines()[-1]


def rewrite(pkg: Package) -> None:
    text = pkg.path.read_text()
    for key, (old, new) in pkg.drift.items():
        pattern = re.compile(rf'({key}\s*=\s*")' + re.escape(old) + r'(")')
        text, count = pattern.subn(rf"\g<1>{new}\g<2>", text, count=1)
        if count != 1:
            raise Problem(f"could not rewrite {key}")
    pkg.path.write_text(text)


def candidates(paths: list[str]) -> list[Path]:
    if paths:
        return [Path(p) for p in paths if p.endswith(".nix") and Path(p).is_file()]
    # Only the packages Renovate actually bumps: the `# renovate:` marker above
    # `version` is the repo's opt-in for the regex manager (see renovate.json), so
    # it is exactly the set whose hashes can go stale unattended.
    return sorted(
        p for p in Path("pkgs").rglob("*.nix") if "# renovate:" in p.read_text()
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="package files (default: every Renovate-tracked one under pkgs/)")
    parser.add_argument("--write", action="store_true", help="rewrite drifted hashes in place")
    parser.add_argument("--json", action="store_true", help="machine-readable report on stdout")
    # A package this script cannot fetch (no fetchFromGitHub, or a hash that is a
    # build output) is reported either way. It only *fails* under --strict, and CI
    # does not pass it: a required check that such a package can never satisfy —
    # not even after a human pins the right hash by hand — is a gate people learn
    # to route around. --strict is for auditing the tree on purpose.
    parser.add_argument("--strict", action="store_true", help="also fail on packages that cannot be verified")
    args = parser.parse_args(argv)

    report: dict[str, dict[str, object]] = {}
    failed = False
    unverified: list[str] = []

    for path in candidates(args.paths):
        try:
            pkg = parse(path)
            fetch(pkg)
        except Problem as exc:
            # Never silent: a file we cannot verify can still break the rebuild,
            # so it is always printed and always in the report.
            print(f"?? {path}: {exc}", file=sys.stderr)
            report[str(path)] = {"status": "unverified", "detail": str(exc)}
            unverified.append(f"{path}: {exc}")
            continue

        if pkg.unverifiable:
            note = (
                f"{path}: pins {', '.join(pkg.unverifiable)} — a build output, not a fetch; "
                "recompute with lib.fakeHash + a real build"
            )
            print(f"?? {note}", file=sys.stderr)
            unverified.append(note)

        if not pkg.drift:
            print(f"ok {path}" + (f" (except {', '.join(pkg.unverifiable)})" if pkg.unverifiable else ""))
            report[str(path)] = {"status": "ok", "unverifiable": pkg.unverifiable}
            continue

        for key, (old, new) in pkg.drift.items():
            print(f"!! {path}: {key}\n     pinned {old}\n     actual {new}")
        report[str(path)] = {
            "status": "fixed" if args.write else "drift",
            "hashes": {k: v[1] for k, v in pkg.drift.items()},
        }
        if args.write:
            rewrite(pkg)
            print(f"-> {path}: rewritten")
        else:
            failed = True

    if unverified:
        print(
            f"\n{len(unverified)} package(s) could not be verified here — build them to be sure:\n  "
            + "\n  ".join(unverified),
            file=sys.stderr,
        )

    if args.json:
        print(json.dumps(report, indent=2))
    return 1 if failed or (unverified and args.strict) else 0


if __name__ == "__main__":
    sys.exit(main())
