# agent-browser — Playwright-style browser-automation CLI for coding agents
# (vercel-labs/agent-browser, Apache-2.0). A single native Rust binary: it drives
# a Chromium over CDP and exposes `navigate` / `snapshot` / `click` / `screenshot`
# subcommands, which is exactly the interface Cyrus's browser-use prompt addendum
# tells the agent to call (hosts/rpi5/agents/cyrus.nix, `enableBrowserUse`).
#
# Why the npm tarballs and not buildNpmPackage: the package has no JS runtime
# dependencies — only optional per-platform packages, each holding one
# prebuilt binary, plus a JS launcher that picks one. There is nothing to
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
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
}:
let
  # renovate: datasource=npm depName=agent-browser
  version = "0.43.0";
in
stdenvNoCC.mkDerivation {
  pname = "agent-browser";
  inherit version;

  # Since 0.43 the main tarball holds only the JS launcher and the skill docs;
  # each platform's binary is its own optional dependency
  # (@agent-browser/cli-<platform>). Only rpi5 runs this (Cyrus), so only
  # aarch64-linux glibc is fetched. Both URLs are literal so
  # scripts/nix-fix-hashes.py can recompute both hashes on a bump.
  #
  # `name` carries the version on purpose (pkgs/README.md, "Fixed-output names"):
  # an FOD's store path is keyed on (outputHash, name), so a bumped `version`
  # beside a stale `hash` must not be able to resolve to the old path.
  src = fetchurl {
    name = "agent-browser-${version}.tgz";
    url = "https://registry.npmjs.org/agent-browser/-/agent-browser-${version}.tgz";
    hash = "sha256-5F07lcES2ghY+KfINtVdvAt4WPrEffFQnXQK3/ZeCrs=";
  };
  binary = fetchurl {
    name = "agent-browser-cli-linux-arm64-gnu-${version}.tgz";
    url = "https://registry.npmjs.org/@agent-browser/cli-linux-arm64-gnu/-/cli-linux-arm64-gnu-${version}.tgz";
    hash = "sha256-RlgjZIrvSpTSC8Kukb7/3vj2jWdQp5Xd28LROSgglDU=";
  };

  # The Rust binary needs only glibc (libc/libm/libpthread/libdl), but it is
  # linked against the generic /lib/ld-linux loader, so the interpreter still
  # has to be rewritten. autoPatchelfHook does both.
  nativeBuildInputs = lib.optional stdenvNoCC.hostPlatform.isLinux autoPatchelfHook;

  installPhase = ''
    runHook preInstall

    tar -xzf $binary --strip-components=2 package/bin/agent-browser
    install -Dm755 agent-browser $out/bin/agent-browser

    # The tarball also ships the agent-facing skill docs the CLI's own
    # AGENT_BROWSER_SKILLS_DIR points at. Small, and useful to hand to an agent.
    # skills/agent-browser (Cyrus's user skill, hosts/rpi5/agents/cyrus.nix) was
    # dropped upstream in 0.43; skill-data/core is the skill it pointed to.
    mkdir -p $out/share/agent-browser/skills
    cp -r skill-data $out/share/agent-browser/skill-data
    cp -r skill-data/core $out/share/agent-browser/skills/agent-browser

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
    platforms = [ "aarch64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
