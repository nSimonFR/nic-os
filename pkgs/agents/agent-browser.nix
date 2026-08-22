# agent-browser — Playwright-style browser-automation CLI for coding agents
# (vercel-labs/agent-browser, Apache-2.0). A single native Rust binary: it drives
# a Chromium over CDP and exposes `navigate` / `snapshot` / `click` / `screenshot`
# subcommands, which is exactly the interface Cyrus's browser-use prompt addendum
# tells the agent to call (hosts/rpi5/cyrus.nix, `enableBrowserUse`).
#
# Why the npm tarball and not buildNpmPackage: the package has ZERO runtime
# dependencies — the registry tarball is just a bag of prebuilt per-platform
# binaries plus a JS launcher that picks one. There is no dependency tree to
# lock, so `fetchurl` + pick-our-platform is the whole build. (The upstream
# `postinstall` downloads a *Chrome for Testing* build too; we skip that — it's
# a generic dynamically-linked ELF that cannot run on NixOS. We pass nixpkgs'
# own chromium via AGENT_BROWSER_EXECUTABLE_PATH instead.)
#
# Bumping: Renovate opens the PR (the `# renovate:` marker below opts this file
# into renovate.json's regex manager, npm datasource) but cannot recompute a Nix
# fixed-output hash, so the `hash` beside `version` arrives stale and the build
# fails on a mismatch. That is the expected shape for everything under pkgs/ —
# the `hashes` check (.github/workflows/nix-hashes.yml) turns the PR red and
# comments the right value. Finish it with:
#   scripts/nix-fix-hashes.py --write pkgs/agents/agent-browser.nix
# That script grew fetchurl support for this package; before, it only understood
# fetchFromGitHub and would have reported "nothing this script knows how to
# fetch", leaving the pin to drift the way affine-mcp-server's did.
{ lib
, stdenvNoCC
, fetchurl
, autoPatchelfHook
}:
let
  # renovate: datasource=npm depName=agent-browser
  version = "0.34.0";

  # The tarball ships one binary per platform under bin/. Map the Nix system
  # onto upstream's naming; glibc only (the musl variants are for Alpine).
  binaries = {
    "aarch64-linux" = "agent-browser-linux-arm64";
    "x86_64-linux" = "agent-browser-linux-x64";
    "aarch64-darwin" = "agent-browser-darwin-arm64";
    "x86_64-darwin" = "agent-browser-darwin-x64";
  };
  inherit (stdenvNoCC.hostPlatform) system;
  binary = binaries.${system} or (throw "agent-browser: unsupported system ${system}");
in
stdenvNoCC.mkDerivation {
  pname = "agent-browser";
  inherit version;

  # `name` carries the version on purpose (pkgs/README.md, "Fixed-output names"):
  # an FOD's store path is keyed on (outputHash, name), so a bumped `version`
  # beside a stale `hash` must not be able to resolve to the old path. fetchurl
  # would default this to the URL's basename, which happens to contain the
  # version already — but that is the URL's shape, not a property we control, so
  # it is stated rather than relied upon.
  src = fetchurl {
    name = "agent-browser-${version}.tgz";
    url = "https://registry.npmjs.org/agent-browser/-/agent-browser-${version}.tgz";
    hash = "sha256-pHRPsYnlmEZ6vPs6zd4HEY2eXLQ9w7MXJ/hpr0651Zg=";
  };

  # The Rust binary needs only glibc (libc/libm/libpthread/libdl), but it is
  # linked against the generic /lib/ld-linux loader, so the interpreter still
  # has to be rewritten. autoPatchelfHook does both.
  nativeBuildInputs = lib.optional stdenvNoCC.hostPlatform.isLinux autoPatchelfHook;

  # We keep exactly one of the seven bundled binaries; the rest are ~70MB of
  # other platforms' dead weight.
  installPhase = ''
    runHook preInstall

    install -Dm755 bin/${binary} $out/bin/agent-browser

    # The tarball also ships the agent-facing skill docs the CLI's own
    # AGENT_BROWSER_SKILLS_DIR points at. Small, and useful to hand to an agent.
    mkdir -p $out/share/agent-browser
    cp -r skills $out/share/agent-browser/skills
    cp -r skill-data $out/share/agent-browser/skill-data

    runHook postInstall
  '';

  # `--version` exercises the patched interpreter without needing a browser.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/agent-browser --version | grep -qF '${version}'
    runHook postInstallCheck
  '';

  meta = {
    description = "Browser automation CLI for AI agents";
    homepage = "https://github.com/vercel-labs/agent-browser";
    license = lib.licenses.asl20;
    mainProgram = "agent-browser";
    platforms = lib.attrNames binaries;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
