# Calino — browser-based CalDAV/CardDAV calendar client
# (github.com/Ivan-Malinovski/calino, MIT).
#
# There is NO backend here. Calino is a React 19 + Vite 8 SPA that speaks
# CalDAV/CardDAV straight from the browser: credentials live in localStorage,
# the event cache is Dexie/IndexedDB. So this derivation is a `vite build` whose
# only output is a directory of static files — nothing to run, nothing to keep
# resident, nothing to back up. hosts/rpi5/calino.nix points an nginx vhost at
# `$out/share/calino/dist` and re-proxies Nextcloud's DAV endpoint under the same
# origin (SabreDAV has no CORS knob, and upstream's answer is a whole extra
# CORS-proxy container).
#
# ⚠ TWO FOD HASHES. `src.hash` and `pnpmDeps.hash` are content hashes of fetched
#   inputs, so both move on a version bump. Renovate can bump `version` but
#   CANNOT recompute either one (see reference_renovate_nix_pins) — such a PR is
#   a notification, not a buildable change. Set the changed one to lib.fakeHash,
#   build once, paste the reported `got: sha256-…`. `src` fails first;
#   `pnpmDeps` only surfaces once `src` is right.
#
# ⚠ pnpm VERSION SKEW. package.json declares `packageManager: pnpm@10.30.3`;
#   nixpkgs' pnpm_10 is 10.28.0. lockfileVersion 9.0 reads on any 10.x, and the
#   fetcher, the config hook and buildPhase each disable
#   `manage-package-manager-versions` so the declaration is never enforced —
#   without that, pnpm tries to fetch 10.30.3 from the registry and the sandbox
#   has no network. That skew is the first thing to suspect if a phase breaks.
{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs_24,
  pnpm_10,
  # The public origin Calino is served at, baked into index.html at build time
  # (canonical link, OG/Twitter cards, JSON-LD). MUST NOT end in a slash — the
  # template interpolates `%VITE_SITE_URL%/`. hosts/rpi5/calino.nix passes the
  # publicUrl derived from the port it declares.
  siteUrl ? "http://localhost",
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "calino";
  # renovate: datasource=github-releases depName=Ivan-Malinovski/calino extractVersion=^v(?<version>.+)$
  version = "0.30.0";

  src = fetchFromGitHub {
    owner = "Ivan-Malinovski";
    repo = "calino";
    tag = "v${finalAttrs.version}";
    # An FOD's store path is keyed on (outputHash, name) — NOT on what it
    # fetched — and fetchFromGitHub defaults name="source". Without a
    # version-bearing name, bumping `version` while forgetting the hash silently
    # re-serves the OLD tree under the new version number. See
    # known_issue_nix_fod_hash_desync; that trap shipped sure-0.7.3 as v0.7.2.
    name = "calino-${finalAttrs.version}-source";
    hash = "sha256-hfoqVhE6502igtcKWqAY/sn+t8zZgkf250MOhDnCQKI=";
  };

  pnpmDeps = pnpm_10.fetchDeps {
    inherit (finalAttrs) pname version src;
    # 3 = reproducible tarball. `pnpm install --force` in the fetcher pulls
    # every platform's optional deps, so unlike the npm-install FODs in
    # showmycards.nix this hash is ONE value across aarch64 and x86_64 — no
    # per-system attrset needed.
    fetcherVersion = 3;
    hash = "sha256-/7Rdhf9rTXLm0AOai9obIBGjvPHoS2UOo0bHZ+IgrSs=";
  };

  nativeBuildInputs = [
    nodejs_24
    pnpm_10
    pnpm_10.configHook
  ];

  # ⚠ UPSTREAM BUG, NOT A PREFERENCE. src/config.ts reads three knobs off
  # `import.meta.env.CALINO_*` (ENABLE_SW, GITHUB_REPO, CONTACT_EMAIL) and
  # README.md/docs/DOCKER.md tell you to set them at build time — but
  # vite.config.ts never sets `envPrefix`, so Vite's default of `VITE_` is in
  # force and NOTHING unprefixed reaches import.meta.env. The knobs are inert:
  # a build with CALINO_ENABLE_SW=true still bakes `enableServiceWorker:!1`
  # (verified by grepping the built bundle), so the service worker never
  # registers and offline mode silently does nothing. Upstream's own Dockerfile
  # has the same hole. Widening the prefix is what makes the documented
  # interface true; it exposes only these CALINO_* build knobs, none of which is
  # a secret.
  #
  # One line, and --replace-fail, so a source bump that moves `base` fails the
  # build instead of quietly reverting the PWA to off. Re-check whether this is
  # still needed on every version bump — if upstream sets envPrefix itself, or
  # switches to VITE_-prefixed names, DROP this.
  postPatch = ''
    substituteInPlace vite.config.ts \
      --replace-fail "base: '/'," "base: '/', envPrefix: ['VITE_', 'CALINO_'],"
  '';

  env = {
    # Offline PWA. Upstream reads this as `import.meta.env.CALINO_ENABLE_SW`
    # (src/config.ts) and gates `navigator.serviceWorker.register('/sw.js')` on
    # it (src/main.tsx). The nginx vhost sends the Service-Worker-Allowed: /
    # header the SW needs to claim the whole origin.
    CALINO_ENABLE_SW = "true";
    # Read via process.env in vite.config.ts → __CALINO_SELF_HOSTED__. Drops the
    # onboarding modal's "load demo data" button, which would otherwise offer to
    # write sample events into a real calendar. Same value upstream's own
    # Dockerfile defaults to for self-hosting.
    CALINO_SELF_HOSTED = "true";
    # The repo ships a committed `.env` pinning this to https://calino.io. Vite's
    # loadEnv lets a real process env var win over .env for VITE_-prefixed keys,
    # so this override lands.
    VITE_SITE_URL = siteUrl;
    CI = "1";
    # tsc -b followed by rollup is the memory peak on a 3.9 GB Pi; cap the heap
    # so it leans on swap instead of being OOM-killed (same guard as
    # showmycards.nix / airtrail-nix).
    NODE_OPTIONS = "--max-old-space-size=3072";
    # Belt-and-braces: both install phases already run --ignore-scripts, so
    # @playwright/test's postinstall never fires.
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  };

  buildPhase = ''
    runHook preBuild
    # ⚠ DO NOT re-point HOME here. pnpmConfigHook exported it to a writable temp
    # dir and wrote `manage-package-manager-versions=false` into that .npmrc.
    # package.json declares `packageManager: pnpm@10.30.3`, so the moment that
    # setting is out of reach `pnpm run build` tries to fetch exactly that pnpm
    # from the registry and dies with ERR_PNPM_META_FETCH_FAIL in the
    # network-less sandbox. Re-asserted below from the PARENT dir — pnpm refuses
    # to read config inside a project whose `packageManager` it has not
    # satisfied — so this holds even if the hook's internals move.
    (cd .. && pnpm config set manage-package-manager-versions false)
    # NODE_ENV is exported HERE and not in `env`: @pnpm/config defaults its
    # `production` flag to NODE_ENV == "production", so setting it globally
    # would make pnpmConfigHook's `pnpm install` omit devDependencies — and
    # vite, tsc and every build plugin live in devDependencies. By buildPhase
    # the install is already done.
    export NODE_ENV=production
    # = node scripts/update-sample-events.mjs && tsc -b && vite build.
    # (The script rewrites public/sample-events.ics to the current month, so it
    # needs a writable source tree — which unpackPhase gives us.)
    pnpm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # vite.config.ts declares two rollup inputs (index.html + headless.html, the
    # Android background-sync entry), so assert on the one nginx actually serves.
    if [ ! -f dist/index.html ]; then
      echo "calino: vite build produced no dist/index.html" >&2
      exit 1
    fi
    mkdir -p "$out/share/calino"
    cp -r dist "$out/share/calino/dist"
    runHook postInstall
  '';

  # Static assets only — there is no ELF here to patch or strip.
  dontFixup = true;

  meta = {
    description = "Browser-based CalDAV/CardDAV calendar client (static SPA)";
    homepage = "https://github.com/Ivan-Malinovski/calino";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
