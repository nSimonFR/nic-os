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

# `<attr> = <something>fetch<Something> {` — the opening of a fetcher call. The
# attribute name matters for reporting ("pnpmDeps.hash"), and the fetcher name
# decides whether its `hash` is something we can re-fetch or a build output.
# Deliberately matches a dotted prefix so `pnpm_10.fetchDeps` is caught.
FETCHER_CALL = re.compile(
    r"(?P<attr>[a-zA-Z_][\w-]*)\s*=\s*(?P<fetcher>[\w.]*\bfetch[A-Za-z]*)\s*\{"
)
# The two we can re-fetch cheaply, and what their `hash` covers.
REFETCHABLE = {"fetchFromGitHub": True, "fetchurl": False}  # name -> unpack?

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
    tarball: str
    # Which hash the `hash` pin actually holds, which is a property of the
    # fetcher rather than of the artifact:
    #   fetchFromGitHub — NAR hash of the *unpacked* tree     (unpack=True)
    #   fetchurl        — flat hash of the downloaded *file*  (unpack=False)
    # Hashing the wrong one produces a plausible-looking value that is simply
    # never what the file pins, so this flag has to follow the fetcher.
    unpack: bool
    pinned: dict[str, str] = field(default_factory=dict)
    actual: dict[str, str] = field(default_factory=dict)
    unverifiable: list[str] = field(default_factory=list)

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
        # `finalAttrs.version` / `self.version`: the mkDerivation fixed-point
        # spelling of a plain top-level binding. calino writes
        # `tag = "v${finalAttrs.version}"`, so without this the file is
        # unresolvable and silently falls out of the gate.
        if name not in bindings and "." in name:
            name = name.rsplit(".", 1)[1]
        if name not in bindings:
            raise Problem(f"cannot resolve ${{{name}}} in {template!r}")
        return bindings[name]

    return INTERP.sub(sub, template)


def fetcher_blocks(text: str) -> list[tuple[str, str, str]]:
    """Every `<attr> = <fetcher> { … }` in the file, as (attr, fetcher, body).

    Brace-matched rather than regexed to the next `}`, so a nested attrset
    inside a fetcher (or a `}` in a comment-free string) does not truncate the
    body. Needed because a `hash` has to be attributed to the fetcher that owns
    it: calino pins two, one per fetcher, and both are literally named `hash`.
    """
    blocks: list[tuple[str, str, str]] = []
    for match in FETCHER_CALL.finditer(text):
        depth, i = 0, match.end() - 1  # sitting on the opening brace
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        else:
            raise Problem(f"unbalanced braces after `{match['attr']} = {match['fetcher']} {{`")
        blocks.append((match["attr"], match["fetcher"], text[match.end() : i]))
    return blocks


def parse(path: Path) -> Package:
    text = path.read_text()

    bindings = {m["key"]: m["val"] for m in BINDING.finditer(text)}
    # `rev = version;` — an unquoted reference to another binding.
    for match in BARE_BINDING.finditer(text):
        if match["key"] not in bindings and match["val"] in bindings:
            bindings[match["key"]] = bindings[match["val"]]

    unverifiable = [key for key in UNVERIFIABLE if re.search(rf"\b{key}\s*=", text)]

    # Attribute every `hash` to the fetcher that owns it. A flat scan of the
    # file cannot: calino pins two hashes, both spelled `hash`, one under
    # fetchFromGitHub and one under pnpm_10.fetchDeps. Collapsing them used to
    # trip a "more than one fetcher" bail that skipped the whole file — which
    # contradicted this script's own rule about vendorHash (see UNVERIFIABLE
    # above) and let calino v0.30.0 merge with a dead src hash, taking main's
    # nginx.conf, and therefore every host's rebuild, down with it.
    blocks = fetcher_blocks(text)
    refetchable = [b for b in blocks if b[1].split(".")[-1] in REFETCHABLE]
    derived = [b for b in blocks if b[1].split(".")[-1] not in REFETCHABLE]

    # A fetcher whose hash is a build output (pnpm store, npm closure, Go vendor
    # tree) is reported, never verified — same treatment as a named vendorHash.
    for attr, fetcher, body in derived:
        if HASH_LINE.search(body):
            # Bare label: main() supplies the "a build output, not a fetch;
            # recompute with lib.fakeHash" explanation for every entry.
            unverifiable.append(f"{attr}.hash ({fetcher})")

    if not refetchable:
        raise Problem("no fetchFromGitHub or fetchurl — nothing this script knows how to fetch")
    if len(refetchable) > 1:
        names = ", ".join(f"{a} = {f}" for a, f, _ in refetchable)
        raise Problem(f"more than one re-fetchable fetcher ({names}) — recompute this one by hand")

    attr, fetcher, body = refetchable[0]
    unpack = REFETCHABLE[fetcher.split(".")[-1]]

    # Only this block's hash is ours to check. `npmDepsHash` stays file-scoped:
    # it sits on the mkDerivation, not inside the fetcher.
    pinned = {m["key"]: m["val"] for m in HASH_LINE.finditer(body) if m["key"] == "hash"}
    if "hash" not in pinned:
        raise Problem(f"`{attr} = {fetcher}` pins no literal `hash`")
    top_level = {m["key"]: m["val"] for m in HASH_LINE.finditer(text) if m["key"] == "npmDepsHash"}
    pinned.update(top_level)

    # Prefer the fetcher's own bindings over file-level ones, so a top-level
    # `url`/`rev` cannot be mistaken for the fetcher's.
    local = dict(bindings)
    local.update({m["key"]: m["val"] for m in BINDING.finditer(body)})

    if unpack:  # fetchFromGitHub
        # `tag` and `rev` are interchangeable here, and calino uses `tag`.
        ref = next((k for k in ("rev", "tag") if k in local), None)
        for key in ("owner", "repo"):
            if key not in local:
                raise Problem(f"no `{key}` binding found")
        if ref is None:
            raise Problem("no `rev` or `tag` binding found")
        # GitHub's /archive/<ref> resolves tags and commits alike, and is the same
        # endpoint fetchFromGitHub itself fetches through — so the NAR hash of the
        # unpacked result is exactly what the `hash` pin holds.
        owner = resolve(local["owner"], local)
        repo = resolve(local["repo"], local)
        rev = resolve(local[ref], local)
        tarball = f"https://github.com/{owner}/{repo}/archive/{rev}.tar.gz"
    else:  # fetchurl
        if "url" not in local:
            raise Problem("fetchurl with no literal `url` binding — recompute this one by hand")
        tarball = resolve(local["url"], local)

    return Package(
        path=path,
        tarball=tarball,
        unpack=unpack,
        pinned=pinned,
        unverifiable=unverifiable,
    )


def fetch(pkg: Package) -> None:
    # --print-path prints the hash, then the store path of the fetched artifact.
    cmd = ["nix-prefetch-url", "--print-path", pkg.tarball]
    if pkg.unpack:
        cmd.insert(1, "--unpack")
    out = run(*cmd).splitlines()
    if len(out) < 2:
        raise Problem(f"unexpected nix-prefetch-url output for {pkg.tarball}")
    pkg.actual["hash"] = to_sri(out[-2])
    src = Path(out[-1])

    if "npmDepsHash" not in pkg.pinned:
        return
    if not pkg.unpack:
        # The store path here is the tarball itself, so there is no tree to read a
        # lockfile out of. No package needs this yet; fail loudly rather than
        # silently leaving npmDepsHash unchecked the way a stale `hash` was.
        raise Problem("pins npmDepsHash alongside fetchurl — recompute this one by hand")
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
