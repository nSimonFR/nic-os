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
output to build. A `hash` pin covers exactly the unpacked tag tarball, and an
`npmDepsHash` pin exactly the closure of a package-lock.json, so fetching those
two is enough.

The dependency stores (pnpmDeps, vendorHash, cargoHash) have no such shortcut:
those alone are built, as the one fixed-output derivation, from
`callPackage <file> { }` on the flake's locked nixpkgs. calino v0.40.0 merged
with a stale pnpmDeps hash on 2026-10-22 while this gate only reported it.

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
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

# `${version}`-style interpolations that appear inside a `rev`. Resolved from
# plain `name = "value";` bindings in the same file, which is all these fetchers
# use in practice (`rev = "v${version}"`, `rev = version`, `repo = pname`).
INTERP = re.compile(r"\$\{([a-zA-Z_][\w.-]*)\}")

BINDING = re.compile(r'^\s*(?P<key>[a-zA-Z_][\w-]*)\s*=\s*"(?P<val>[^"]*)"\s*;', re.M)
BARE_BINDING = re.compile(
    r"^\s*(?P<key>[a-zA-Z_][\w-]*)\s*=\s*(?P<val>[a-zA-Z_][\w.-]*)\s*;", re.M
)
HASH_LINE = re.compile(r'(?P<key>\bhash|\bnpmDepsHash)\s*=\s*"(?P<val>[^"]*)"')

# `<attr> = <something>fetch<Something> {` — the opening of a fetcher call. The
# attribute name matters for reporting ("pnpmDeps.hash"), and the fetcher name
# decides whether its `hash` is something we can re-fetch or a build output.
# Deliberately matches a dotted prefix so `pnpm_10.fetchDeps` is caught.
FETCHER_CALL = re.compile(
    r"(?P<attr>[a-zA-Z_][\w-]*)\s*=\s*(?P<fetcher>[\w.]*\b(?:fetch[A-Za-z]*|pullImage))\s*\{"
)
# The two we can re-fetch cheaply, and what their `hash` covers.
REFETCHABLE = {"fetchFromGitHub": True, "fetchurl": False, "fetchPypi": False}
PYPI_URL = "https://files.pythonhosted.org/packages/source/{p0}/{pname}/{pname}-{version}.tar.gz"
# `hash = { linux_arm64 = "sha256-…"; … }.${platform};` — one pin per platform.
INLINE_MAP = re.compile(r"\bhash\s*=\s*\{(?P<map>[^{}]*)\}\s*\.\s*\$\{(?P<var>\w+)\}")
MAP_ENTRY = re.compile(r'(?P<key>[\w-]+)\s*=\s*"(?P<val>sha256-[^"]+)"')
# `assets = { <system> = { asset = "…"; hash = "…"; }; … };` read through
# `inherit (target) hash;` and `${target.asset}` in the url.
ASSET_ENTRY = re.compile(
    r'(?P<sys>[\w-]+)\s*=\s*\{\s*asset\s*=\s*"(?P<asset>[^"]+)";\s*hash\s*=\s*"(?P<hash>sha256-[^"]+)";\s*\}'
)
# dockerTools.pullImage's per-arch entries: `{ arch; imageDigest; hash; }`.
IMAGE_ENTRY = re.compile(
    r'arch\s*=\s*"(?P<arch>[^"]+)";\s*imageDigest\s*=\s*"(?P<digest>sha256:[0-9a-f]+)";\s*hash\s*=\s*"(?P<hash>sha256-[^"]+)";'
)

# Hashes this script cannot derive from a fetch: they are the output of a build
# (Go module vendoring, a pnpm store, a Cargo vendor tree). Their presence does
# NOT stop the file being checked — blogwatcher pins a `vendorHash` and still
# shipped a wrong `src.hash` on 2026-08-19, so bailing on the whole file would
# skip exactly the hash this can verify. They are reported alongside the result.
UNVERIFIABLE = ("vendorHash", "cargoHash", "pnpmDepsHash", "cargoDeps")

# Of those, the ones derive() can build: pin name -> the derivation attribute
# that holds it. A fetcher-scoped `<attr>.hash` (pnpmDeps) builds `<attr>`.
DERIVABLE = {"vendorHash": "goModules", "cargoHash": "cargoDeps"}
DERIVABLE_FETCHERS = ("fetchDeps", "fetchPnpmDeps")
MISMATCH = re.compile(r"hash mismatch in fixed-output derivation '(?P<drv>[^']+)'")
GOT = re.compile(r"got:\s+(?P<val>sha256-\S+)")

# A second, unrelated pin shape: a package that hands nixpkgs an upstream
# release manifest as a Nix attrset (pkgs/agents/claude-code.nix). There is no
# fetcher in the file at all — nixpkgs owns the fetchurl — so the checksums are
# copied from a published manifest rather than computed. Checking them is
# therefore a JSON fetch and a string compare, with no Nix invocation and
# nothing downloaded: cheaper than the tarball path below.
MANIFEST_URL = (
    "https://downloads.claude.ai/claude-code-releases/{version}/manifest.zst.json"
)
MANIFEST_VERSION = re.compile(
    r'#\s*renovate:[^\n]*\n\s*version\s*=\s*"(?P<val>[^"]+)"\s*;'
)
MANIFEST_PLATFORM = re.compile(
    r'"(?P<key>[a-z0-9]+-[a-z0-9-]+)"\s*=\s*\{[^{}]*?checksum\s*=\s*"(?P<val>[0-9a-f]{64})"',
    re.S,
)


class Problem(Exception):
    """A file this script cannot speak for. Never silently skipped."""


@dataclass
class Source:
    """One fetch whose result a pin in the file must equal."""

    key: str
    url: str
    unpack: bool
    # pullImage: (imageName, tag, arch, finalImageName); `url` is unused.
    image: tuple[str, str, str, str] | None = None


@dataclass
class Package:
    path: Path
    tarball: str = ""
    # Which hash the `hash` pin actually holds, which is a property of the
    # fetcher rather than of the artifact:
    #   fetchFromGitHub — NAR hash of the *unpacked* tree     (unpack=True)
    #   fetchurl        — flat hash of the downloaded *file*  (unpack=False)
    # Hashing the wrong one produces a plausible-looking value that is simply
    # never what the file pins, so this flag has to follow the fetcher.
    unpack: bool = False
    sources: list[Source] = field(default_factory=list)
    # Non-empty for the upstream-manifest shape above: the version whose
    # published manifest the checksums are compared against. Switches `fetch`
    # and `rewrite` onto that path, where the dict keys are platform names and
    # every pin is spelled `checksum` rather than `hash`.
    manifest_version: str = ""
    pinned: dict[str, str] = field(default_factory=dict)
    actual: dict[str, str] = field(default_factory=dict)
    unverifiable: list[str] = field(default_factory=list)
    # pin key -> derivation attribute to build for it (see derive()).
    derived: dict[str, str] = field(default_factory=dict)
    # Directory of the npm project inside the source tree, from `sourceRoot`
    # (freereps builds its frontend from server/web). Empty = the tree's root.
    npm_root: str = ""

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
        raise Problem(
            f"{cmd[0]} failed: {(proc.stderr or proc.stdout).strip().splitlines()[-1:]}"
        )
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
            raise Problem(
                f"unbalanced braces after `{match['attr']} = {match['fetcher']} {{`"
            )
        blocks.append((match["attr"], match["fetcher"], text[match.end() : i]))
    return blocks


def parse(path: Path) -> Package:
    text = path.read_text()

    # The upstream-manifest shape short-circuits everything below: no fetcher to
    # attribute a hash to, and the pins are per-platform `checksum` entries.
    version = MANIFEST_VERSION.search(text)
    platforms = {m["key"]: m["val"] for m in MANIFEST_PLATFORM.finditer(text)}
    if version and platforms:
        return Package(
            path=path,
            tarball=MANIFEST_URL.format(version=version["val"]),
            unpack=False,
            manifest_version=version["val"],
            pinned=platforms,
        )

    bindings = {m["key"]: m["val"] for m in BINDING.finditer(text)}
    # `rev = version;` — an unquoted reference to another binding.
    for match in BARE_BINDING.finditer(text):
        if match["key"] not in bindings and match["val"] in bindings:
            bindings[match["key"]] = bindings[match["val"]]

    unverifiable = [key for key in UNVERIFIABLE if re.search(rf"\b{key}\s*=", text)]
    derived_pins: dict[str, str] = {}
    derived_attrs: dict[str, str] = {}
    for key, attr in DERIVABLE.items():
        match = re.search(rf'\b{key}\s*=\s*"(?P<val>sha256-[^"]+)"', text)
        if match:
            derived_pins[key], derived_attrs[key] = match["val"], attr

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
        match = HASH_LINE.search(body)
        if not match:
            continue
        if fetcher.split(".")[-1] in DERIVABLE_FETCHERS and match["val"].startswith(
            "sha256-"
        ):
            derived_pins[f"{attr}.hash"], derived_attrs[f"{attr}.hash"] = (
                match["val"],
                attr,
            )
        else:
            # Bare label: main() supplies the "a build output, not a fetch;
            # recompute with lib.fakeHash" explanation for every entry.
            unverifiable.append(f"{attr}.hash ({fetcher})")
    unverifiable = [key for key in unverifiable if key not in derived_attrs]

    images = [b for b in blocks if b[1].split(".")[-1] == "pullImage"]
    if not refetchable and not images:
        if not (HASH_LINE.search(text) or derived_pins or unverifiable):
            return Package(path=path)  # nothing content-addressed to go stale
        raise Problem(
            "no fetchFromGitHub, fetchurl, fetchPypi or pullImage — nothing this script knows how to fetch"
        )

    sources: list[Source] = []
    pinned: dict[str, str] = {}
    many = len(refetchable) + len(images) > 1

    for attr, fetcher, body in refetchable:
        kind = fetcher.split(".")[-1]
        unpack = REFETCHABLE[kind]
        # Prefer the fetcher's own bindings over file-level ones, so a top-level
        # `url`/`rev` cannot be mistaken for the fetcher's.
        local = dict(bindings)
        local.update({m["key"]: m["val"] for m in BINDING.finditer(body)})

        variants: list[tuple[str, str, dict[str, str]]] = []
        inline = INLINE_MAP.search(body)
        own = [m["val"] for m in HASH_LINE.finditer(body) if m["key"] == "hash"]
        if inline:
            for m in MAP_ENTRY.finditer(inline["map"]):
                variants.append((f"[{m['key']}]", m["val"], {inline["var"]: m["key"]}))
        elif re.search(r"inherit\s*\(\s*\w+\s*\)\s*hash\s*;", body):
            for m in ASSET_ENTRY.finditer(text):
                variants.append((f"[{m['sys']}]", m["hash"], {"asset": m["asset"]}))
        elif own:
            variants.append(("", own[0], {}))
        if not variants:
            raise Problem(f"`{attr} = {fetcher}` pins no literal `hash`")

        for suffix, value, extra in variants:
            loc = local | extra
            key = (f"{attr}.hash" if many else "hash") + suffix
            sources.append(Source(key, fetch_url(kind, loc), unpack))
            pinned[key] = value

    for attr, _, body in images:
        local = dict(bindings)
        local.update({m["key"]: m["val"] for m in BINDING.finditer(body)})
        tag_ref = re.search(r"finalImageTag\s*=\s*(?P<ref>[\w.]+)\s*;", body)
        tag = local.get("finalImageTag") or (
            bindings.get(tag_ref["ref"].rsplit(".", 1)[-1]) if tag_ref else None
        )
        if not (tag and "imageName" in local):
            raise Problem(
                f"`{attr}` pullImage without a literal imageName/finalImageTag"
            )
        entries = list(IMAGE_ENTRY.finditer(text))
        if not entries:
            raise Problem(f"`{attr}` pullImage: no arch/imageDigest/hash entry found")
        for m in entries:
            key = f"{attr}[{m['arch']}]"
            final = local.get("finalImageName", local["imageName"])
            sources.append(
                Source(key, "", False, (local["imageName"], tag, m["arch"], final))
            )
            pinned[f"{key}.imageDigest"] = m["digest"]
            pinned[f"{key}.hash"] = m["hash"]

    # `npmDepsHash` sits on the mkDerivation, so it belongs to the one source tree.
    npm = {
        m["key"]: m["val"]
        for m in HASH_LINE.finditer(text)
        if m["key"] == "npmDepsHash"
    }
    if npm and [src.unpack for src in sources] != [True]:
        raise Problem(
            "pins npmDepsHash without exactly one fetchFromGitHub — recompute by hand"
        )
    pinned.update(npm)

    root = re.search(r'sourceRoot\s*=\s*"\$\{[^}]+\}/(?P<sub>[^"]+)"', text)
    return Package(
        path=path,
        sources=sources,
        pinned=pinned | derived_pins,
        unverifiable=unverifiable,
        derived=derived_attrs,
        npm_root=root["sub"] if root else "",
    )


def fetch_url(kind: str, local: dict[str, str]) -> str:
    if kind == "fetchFromGitHub":
        # `tag` and `rev` are interchangeable here, and calino uses `tag`.
        ref = next((k for k in ("rev", "tag") if k in local), None)
        for key in ("owner", "repo"):
            if key not in local:
                raise Problem(f"no `{key}` binding found")
        if ref is None:
            raise Problem("no `rev` or `tag` binding found")
        # GitHub's /archive/<ref> is the endpoint fetchFromGitHub itself uses.
        owner, repo = resolve(local["owner"], local), resolve(local["repo"], local)
        return f"https://github.com/{owner}/{repo}/archive/{resolve(local[ref], local)}.tar.gz"
    if kind == "fetchPypi":
        if "pname" not in local or "version" not in local:
            raise Problem("fetchPypi without literal `pname` and `version`")
        pname = resolve(local["pname"], local)
        return PYPI_URL.format(p0=pname[0], pname=pname, version=local["version"])
    if "url" not in local:
        raise Problem(
            "fetchurl with no literal `url` binding — recompute this one by hand"
        )
    return resolve(local["url"], local)


def fetch(pkg: Package) -> None:
    if pkg.manifest_version:
        # urllib, not nix-prefetch-url: the answer is published, so there is
        # nothing to hash and nothing to put in the store.
        try:
            with urllib.request.urlopen(pkg.tarball, timeout=30) as response:
                manifest = json.load(response)
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            raise Problem(f"could not read {pkg.tarball}: {exc}") from exc
        published = manifest.get("platforms", {})
        missing = [key for key in pkg.pinned if key not in published]
        if missing:
            raise Problem(
                f"{pkg.manifest_version} publishes no entry for {', '.join(sorted(missing))}"
            )
        pkg.actual = {key: published[key]["checksum"] for key in pkg.pinned}
        return

    tree: Path | None = None
    for src in pkg.sources:
        if src.image:
            name, tag, arch, final = src.image
            out = json.loads(
                run(
                    "nix",
                    "run",
                    "nixpkgs#nix-prefetch-docker",
                    "--",
                    "--image-name",
                    name,
                    "--image-tag",
                    tag,
                    "--arch",
                    arch,
                    "--os",
                    "linux",
                    "--final-image-name",
                    final,
                    "--final-image-tag",
                    tag,
                    "--json",
                    "--quiet",
                )
            )
            # The tool reports the index digest, the file may pin the per-arch
            # one: both pull the same image, so only a new hash moves the digest.
            new_hash = to_sri(out.get("hash") or out["sha256"])
            same = new_hash == pkg.pinned[f"{src.key}.hash"]
            pkg.actual[f"{src.key}.hash"] = new_hash
            pkg.actual[f"{src.key}.imageDigest"] = (
                pkg.pinned[f"{src.key}.imageDigest"] if same else out["imageDigest"]
            )
            continue
        # --print-path prints the hash, then the store path of the fetched artifact.
        cmd = ["nix-prefetch-url", "--print-path", src.url]
        if src.unpack:
            cmd.insert(1, "--unpack")
        out = run(*cmd).splitlines()
        if len(out) < 2:
            raise Problem(f"unexpected nix-prefetch-url output for {src.url}")
        pkg.actual[src.key] = to_sri(out[-2])
        if src.unpack:
            tree = Path(out[-1])

    if "npmDepsHash" not in pkg.pinned:
        return
    assert tree is not None  # parse() guarantees exactly one unpacked source
    lock = tree / pkg.npm_root / "package-lock.json"
    if not lock.is_file():
        raise Problem(
            f"pins npmDepsHash but the tag has no {pkg.npm_root or '.'}/package-lock.json"
        )
    pkg.actual["npmDepsHash"] = run(
        "nix", "run", "nixpkgs#prefetch-npm-deps", "--", str(lock)
    ).splitlines()[-1]


def nixpkgs_ref() -> str:
    lock = json.loads(Path("flake.lock").read_text())
    locked = lock["nodes"][lock["nodes"]["root"]["inputs"]["nixpkgs"]]["locked"]
    return f"github:{locked['owner']}/{locked['repo']}/{locked['rev']}"


def derive(pkg: Package) -> None:
    """Build each dependency store and take the hash Nix reports.

    A stale pin fails with `got: <hash>`; a correct one builds (or substitutes).
    The mismatch must name the store's own drv — a stale `src` would otherwise
    hand back the source hash under the store's name.
    """
    for key, attr in pkg.derived.items():
        expr = (
            f'(builtins.getFlake "{nixpkgs_ref()}").legacyPackages.${{builtins.currentSystem}}'
            f".callPackage {pkg.path.resolve()} {{ }}"
        )
        try:
            drv = run(
                "nix", "eval", "--impure", "--raw", "--expr", f"({expr}).{attr}.drvPath"
            )
        except Problem as exc:
            raise Problem(
                f"cannot evaluate {attr} via callPackage {{ }}: {exc}"
            ) from exc
        proc = subprocess.run(
            ["nix", "build", "--no-link", "--impure", "--expr", f"({expr}).{attr}"],
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0:
            pkg.actual[key] = pkg.pinned[key]
            continue
        mismatch, got = MISMATCH.search(proc.stderr), GOT.search(proc.stderr)
        if not (mismatch and got and mismatch["drv"] == drv):
            tail = proc.stderr.strip().splitlines()[-3:]
            raise Problem(
                f"building {attr} failed without a usable hash mismatch: {tail}"
            )
        pkg.actual[key] = got["val"]


def rewrite(pkg: Package) -> None:
    text = pkg.path.read_text()
    for key, (old, new) in pkg.drift.items():
        # Every pin is a unique quoted literal, so the old value alone anchors it.
        if text.count(f'"{old}"') != 1:
            raise Problem(f"could not rewrite {key}: {old} is not unique in the file")
        text = text.replace(f'"{old}"', f'"{new}"')
    pkg.path.write_text(text)


def candidates(paths: list[str]) -> list[Path]:
    if paths:
        return [Path(p) for p in paths if p.endswith(".nix") and Path(p).is_file()]
    # Only the packages Renovate actually bumps: the `# renovate:` marker above
    # `version` is the repo's opt-in for the regex manager (see renovate.json), so
    # it is exactly the set whose hashes can go stale unattended.
    return sorted(
        p
        for root in ("pkgs", "hosts")
        for p in Path(root).rglob("*.nix")
        if "# renovate:" in p.read_text()
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        help="package files (default: every Renovate-tracked one under pkgs/ and hosts/)",
    )
    parser.add_argument(
        "--write", action="store_true", help="rewrite drifted hashes in place"
    )
    parser.add_argument(
        "--json", action="store_true", help="machine-readable report on stdout"
    )
    # A package this script cannot fetch (no fetchFromGitHub, or a hash that is a
    # build output) is reported either way. It only *fails* under --strict, and CI
    # does not pass it: a required check that such a package can never satisfy —
    # not even after a human pins the right hash by hand — is a gate people learn
    # to route around. --strict is for auditing the tree on purpose.
    parser.add_argument(
        "--strict",
        action="store_true",
        help="also fail on packages that cannot be verified",
    )
    args = parser.parse_args(argv)

    report: dict[str, dict[str, object]] = {}
    failed = False
    unverified: list[str] = []

    for path in candidates(args.paths):
        try:
            pkg = parse(path)
            fetch(pkg)
            # The stores are built from `src`, so `src` has to be right first.
            if pkg.derived and args.write and pkg.drift:
                rewrite(pkg)
                pkg.pinned.update(pkg.actual)
            if pkg.derived and not pkg.drift:
                derive(pkg)
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
            print(
                f"ok {path}"
                + (
                    f" (except {', '.join(pkg.unverifiable)})"
                    if pkg.unverifiable
                    else ""
                )
            )
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
