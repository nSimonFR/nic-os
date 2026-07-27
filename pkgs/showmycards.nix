# ShowMyCards — self-hosted Magic: The Gathering collection manager
# (github.com/showmycards/showmycards, MIT). Built from source for aarch64:
# upstream only publishes an amd64 container image, so the prebuilt image can't
# run on the rpi5. Same local-vendoring model as pkgs/rtk.nix — a `flake = false`
# source input (showmycards-src, pinned in flake.nix) built here and exposed as
# `pkgs.showmycards` via an overlay.
#
# Upstream bundles backend + frontend in one supervisord container. We build
# both and expose two wrappers consumed by rpi5/showmycards.nix:
#   * $out/bin/showmycards-backend   — Go/Fiber API (SQLite, cgo); GODEBUG pinned
#   * $out/bin/showmycards-frontend  — SvelteKit adapter-node server (`node build`)
#
# node_modules are materialised by fixed-output derivations that run
# `npm install` (network is allowed in FODs). We use npm --legacy-peer-deps
# rather than upstream's `bun install` because bun 1.3.x mis-extracts daisyui's
# root files (index.js / daisyui.css from its package `files` field) →
# "@tailwindcss/vite: Failed to resolve entry for package daisyui". npm honours
# `files` correctly. The repo ships bun.lock (no package-lock.json), so the FOD
# outputHash — not a lockfile — is what pins determinism here.
#
# ⚠ HASHES. vendorHash + the two FOD outputHashes below are content hashes of
#   fetched dependencies, so they change whenever the pinned source's go.sum or
#   frontend deps move. After bumping showmycards-src, set the changed one back
#   to lib.fakeHash, build once, and paste the `got: sha256-…` Nix reports.
#
# ⚠ SOURCE PATCHES. `postPatch` on the backend rewrites two things in
#   backend/services/bulk_data.go: the bulk-download client timeout (30min →
#   6h) and a card-language filter (keep en + fr only). Without the first the
#   import cannot finish on this hardware at all; the second is a deliberate
#   scope choice. Both use --replace-fail, so a source bump that moves those
#   lines fails the build loudly instead of silently dropping the patch —
#   re-anchor them rather than deleting them. Details at the call site below.
#
# ⚠ GO TOOLCHAIN. backend/go.mod requires `go 1.26.3`, and a pure Nix build
#   cannot fetch a toolchain (GOTOOLCHAIN=auto has no network in the build
#   sandbox), so the `go` passed in must already satisfy it. nixpkgs' default
#   `go` is 1.25.10 — too old — so flake.nix passes `go = final.go_1_26`
#   (1.26.4), matching upstream's golang:1.26-alpine build image.
{
  lib,
  stdenv,
  stdenvNoCC,
  showmycards-src,
  buildGoModule,
  go,
  gcc,
  nodejs_22,
  cacert,
  makeWrapper,
}:

let
  pname = "showmycards";
  version = "0.3.0"; # keep in lock-step with the showmycards-src tag in flake.nix
  src = showmycards-src;

  # ── Go backend (cgo: mattn/go-sqlite3) ────────────────────────────────────
  backend = (buildGoModule.override { inherit go; }) {
    pname = "showmycards-backend";
    inherit version src;
    modRoot = "backend";
    vendorHash = "sha256-WPOJe+v/gVJX/Q8Rm7Jtd6EB0rW5Wc0CoCA8dbj0US0=";
    nativeBuildInputs = [ gcc ];
    env.CGO_ENABLED = "1";
    ldflags = [ "-X" "backend/version.Version=${version}" ];

    # ⚠ BULK IMPORT PATCHES — both are required for `all_cards` to import at
    #   all on the rpi5. See the header note for the full reasoning.
    #
    #   1. Timeout. Upstream gives the bulk download an `http.Client{Timeout:
    #      30 * time.Minute}`. Go's Client.Timeout bounds the WHOLE exchange
    #      including reading the body, and the importer stream-decodes cards
    #      straight off that body — so it's a budget for the entire import, not
    #      the download. The rpi5 sustains ~90 inserts/s, so any dataset over
    #      ~160k cards is unimportable: the 2026-07-27 run died at exactly
    #      30m09s / 181000 cards with "context deadline exceeded ... while
    #      reading body". 6h leaves plenty of headroom while still bounding a
    #      genuinely wedged transfer.
    #
    #   2. Language filter. `all_cards` is every printing in every language:
    #      535598 objects, ~2.7 GB of SQLite. We only want en + fr (113565 +
    #      57593 = 171158), so drop everything else before it reaches the
    #      insert batch. Note this filters the FULL all_cards stream rather
    #      than switching to Scryfall's smaller `default_cards` bulk file,
    #      because default_cards is English-or-sole-language and so would not
    #      give us French printings at all.
    #
    #   Written as one-liners on purpose: the Go source is tab-indented, and
    #   Nix indented-string literals rewrite leading whitespace, which would
    #   silently corrupt a multi-line replacement.
    postPatch = ''
      substituteInPlace backend/services/bulk_data.go \
        --replace-fail 'Timeout: 30 * time.Minute' 'Timeout: 6 * time.Hour' \
        --replace-fail 'batch = append(batch, card)' 'if card.Lang != "en" && card.Lang != "fr" { continue }; batch = append(batch, card)'
    '';

    # Upstream tests hit the network / fixtures; skip for the packaged build.
    doCheck = false;
  };

  # ── Frontend node_modules via fixed-output derivations (npm, see header) ───
  mkNpmModules = { name, npmArgs, outputHash }:
    stdenvNoCC.mkDerivation {
      name = "showmycards-frontend-${name}-${version}";
      inherit src;
      nativeBuildInputs = [ nodejs_22 cacert ];
      dontUnpack = true;
      dontConfigure = true;
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        export HOME=$TMPDIR
        export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
        export npm_config_cache=$TMPDIR/npm-cache
        # Skip browser/binary downloads pulled by some devDeps (playwright).
        export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
        # Copy the frontend subtree out of the read-only source and install there.
        cp -R ${src}/frontend/. .
        chmod -R u+w .
        npm install ${npmArgs} --legacy-peer-deps --no-audit --no-fund --no-progress
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        rm -rf node_modules/.cache
        mkdir -p $out
        cp -R node_modules $out/node_modules
        runHook postInstall
      '';
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      inherit outputHash;
    };

  # Full tree (dev + prod) used to run `vite build`.
  depsBuild = mkNpmModules {
    name = "deps-build";
    npmArgs = "";
    outputHash = "sha256-90sxgYWGHQyIo/GIABnOSHi4B9D/2pMo1oLpjelc0Zc=";
  };

  # Production-only tree shipped at runtime. adapter-node keeps `dependencies`
  # external (see frontend package.json), so `node build` needs them present.
  depsProd = mkNpmModules {
    name = "deps-prod";
    npmArgs = "--omit=dev";
    outputHash = "sha256-rRC6hQkeHLzv7o9LV3R5GZzc7hp7vb4F5Ogw+lDPy5Y=";
  };

in
stdenv.mkDerivation {
  inherit pname version;
  dontUnpack = true;

  nativeBuildInputs = [ nodejs_22 makeWrapper ];

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    cp -R ${src}/frontend/. ./frontend
    chmod -R u+w frontend
    cd frontend
    cp -R ${depsBuild}/node_modules ./node_modules
    chmod -R u+w node_modules
    # node_modules/.bin shebangs are `#!/usr/bin/env node`; /usr/bin/env doesn't
    # exist in the pure build sandbox. Rewrite to the store node.
    patchShebangs node_modules
    export NODE_ENV=production
    # Vite/Rollup are memory-hungry; cap heap so the rpi5 leans on swap rather
    # than being OOM-killed mid-build (same guard as airtrail-nix).
    export NODE_OPTIONS=--max-old-space-size=3072
    npm run build
    cd ..
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    fdir=$out/share/showmycards/frontend
    mkdir -p "$fdir" $out/bin
    cp -R frontend/build         "$fdir/build"
    cp    frontend/package.json  "$fdir/package.json"
    cp -R ${depsProd}/node_modules "$fdir/node_modules"

    # Frontend: `node build` from the adapter-node output dir.
    makeWrapper ${nodejs_22}/bin/node $out/bin/showmycards-frontend \
      --add-flags "$fdir/build" \
      --chdir "$fdir"

    # Backend: force HTTP/1.1 for the large streamed Scryfall bulk import —
    # Go's HTTP/2 client chokes on the ~multi-GB all_cards gzip stream with
    # "PROTOCOL_ERROR" on the rpi5 (observed during the throwaway test).
    makeWrapper ${backend}/bin/backend $out/bin/showmycards-backend \
      --set GODEBUG http2client=0
    runHook postInstall
  '';

  meta = {
    description = "Self-hosted Magic: The Gathering collection manager (from source)";
    homepage = "https://showmy.cards";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
