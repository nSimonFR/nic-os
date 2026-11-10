# ShowMyCards — self-hosted Magic: The Gathering collection manager
# (github.com/showmycards/showmycards, MIT). Built from source for aarch64:
# the only published container image is amd64, so it can't run on the rpi5.
# (Upstream added multi-arch amd64+arm64 CI in 51d7268c, but that landed after
# v0.3.0 and no release has been cut since, so no arm64 image exists yet. Once
# one ships, this whole from-source build may become unnecessary — re-evaluate.)
# Same local-vendoring model as pkgs/agents/rtk.nix — a `flake = false`
# source input (showmycards-src, pinned in flake.nix) built here and exposed as
# `pkgs.showmycards` via an overlay.
#
# Upstream bundles backend + frontend in one supervisord container. We build
# both and expose two wrappers consumed by hosts/rpi5/life/showmycards.nix:
#   * $out/bin/showmycards-backend   — Go/Fiber API (SQLite, cgo); GODEBUG pinned
#   * $out/bin/showmycards-frontend  — SvelteKit adapter-node server (`node build`)
#
# node_modules are built offline from ./showmycards-package-lock.json with
# importNpmLock, so no output hash can drift with the npm registry. Upstream ships
# bun.lock only, and bun 1.3.x mis-extracts daisyui's root files ("@tailwindcss/vite:
# Failed to resolve entry for package daisyui"), hence npm + --legacy-peer-deps.
#
# ⚠ LOCKFILE. It must match showmycards-src's frontend/package.json; a stale one
#   fails the build offline. After bumping the source, regenerate it:
#     cp <src>/frontend/package.json /tmp/fe && cd /tmp/fe &&
#     npm install --package-lock-only --legacy-peer-deps
#   and copy the package-lock.json over the vendored one.
#
# ⚠ HASH. Only the Go `vendorHash` below is a content hash; after a go.sum change
#   set it to lib.fakeHash, build once, and paste the `got: sha256-…` Nix reports.
#
# ⚠ SOURCE PATCHES. `postPatch` rewrites the bulk-import timeout, adds an en+fr
#   language filter (see the call site), and lowers go.mod's toolchain floor (see
#   ⚠ GO TOOLCHAIN). They use --replace-fail, so a source bump that moves those
#   lines fails the build — re-anchor, don't drop.
#
# ⚠ GO TOOLCHAIN — go.mod ASKS FOR MORE THAN NIXPKGS HAS. A pure Nix build cannot
#   fetch a toolchain (GOTOOLCHAIN=auto has no network in the build sandbox), so
#   the `go` passed in must already satisfy go.mod. nixpkgs' default `go` is
#   1.25.10 — too old — so flake.nix passes `go = final.go_1_26`. But that is
#   1.26.4, and upstream's 2dcbd344 raised backend/go.mod to `go 1.26.5`
#   ("clear govulncheck findings"), which nothing in nixpkgs provides yet:
#
#     go: go.mod requires go >= 1.26.5 (running go 1.26.4; GOTOOLCHAIN=local)
#
#   So postPatch rewrites the directive back to 1.26.4. Safe: 1.26.5 is a patch
#   release, and Go patch releases add no language features — the directive is
#   toolchain selection, not a source-compatibility gate. What we DON'T get is
#   whatever stdlib fix landed in 1.26.5; that is unobtainable here regardless,
#   since 1.26.4 is the nixpkgs ceiling and is what this host already runs.
#   DROP THE go.mod REWRITE the moment nixpkgs ships go 1.26.5 — re-check with
#   `nix eval --raw nixpkgs#go_1_26.version`.
{
  lib,
  stdenv,
  showmycards-src,
  buildGoModule,
  go,
  gcc,
  nodejs_22,
  importNpmLock,
  makeWrapper,
}:

let
  pname = "showmycards";
  # nixpkgs "unstable" convention: <last release>-unstable-<commit date>, because
  # showmycards-src is pinned to a commit past v0.3.0, not to a tag. See the
  # ⚠ PINNED TO A COMMIT note in flake.nix; keep both in lock-step.
  version = "0.3.0-unstable-2026-07-20";
  src = showmycards-src;

  # ── Go backend (cgo: mattn/go-sqlite3) ────────────────────────────────────
  backend = (buildGoModule.override { inherit go; }) {
    pname = "showmycards-backend";
    inherit version src;
    modRoot = "backend";
    vendorHash = "sha256-WPOJe+v/gVJX/Q8Rm7Jtd6EB0rW5Wc0CoCA8dbj0US0=";
    nativeBuildInputs = [ gcc ];
    env.CGO_ENABLED = "1";
    ldflags = [
      "-X"
      "backend/version.Version=${version}"
    ];

    # Both edits are required for the import to finish on the rpi5.
    #
    #   1. Go's Client.Timeout bounds the whole exchange including the body
    #      read, and the importer stream-decodes off that body — so upstream's
    #      30min is a budget for the entire import. At ~90 inserts/s the
    #      2026-07-27 run died at 30m09s / 181000 cards. 6h still bounds a
    #      wedged transfer.
    #   2. Keep only en+fr: 171158 rows instead of all_cards' 535598, ~0.9 GB
    #      instead of ~2.7. (Not Scryfall's default_cards feed — that is
    #      English-or-sole-language, so it carries no French printings.)
    #
    # One-liners on purpose: the source is tab-indented and Nix indented
    # strings rewrite leading whitespace, corrupting multi-line replacements.
    postPatch = ''
      substituteInPlace backend/services/bulk_data.go \
        --replace-fail 'Timeout: 30 * time.Minute' 'Timeout: 6 * time.Hour' \
        --replace-fail 'batch = append(batch, card)' 'if card.Lang != "en" && card.Lang != "fr" { continue }; batch = append(batch, card)'
      substituteInPlace backend/go.mod \
        --replace-fail 'go 1.26.5' 'go 1.26.4'
    '';

    # Upstream tests hit the network / fixtures; skip for the packaged build.
    doCheck = false;
  };

  # ── Frontend node_modules, offline from the vendored lockfile ──────────────
  mkNpmModules =
    { name, npmFlags }:
    importNpmLock.buildNodeModules {
      nodejs = nodejs_22;
      package =
        let
          pkg = lib.importJSON "${src}/frontend/package.json";
        in
        # importNpmLock rewrites direct deps to store paths, so an override that
        # repeats a direct dependency's range (vite) must refer to it instead.
        pkg
        // {
          overrides = pkg.overrides // {
            vite = "$vite";
          };
        };
      packageLock = lib.importJSON ./showmycards-package-lock.json;
      derivationArgs = {
        pname = "showmycards-frontend-${name}";
        inherit version;
        npmFlagsArray = npmFlags;
        # Skip browser binary downloads pulled by some devDeps (playwright).
        PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
      };
    };

  # Full tree (dev + prod) used to run `vite build`.
  depsBuild = mkNpmModules {
    name = "deps-build";
    npmFlags = [ "--legacy-peer-deps" ];
  };

  # Production-only tree shipped at runtime. adapter-node keeps `dependencies`
  # external (see frontend package.json), so `node build` needs them present.
  depsProd = mkNpmModules {
    name = "deps-prod";
    npmFlags = [
      "--legacy-peer-deps"
      "--omit=dev"
    ];
  };

in
stdenv.mkDerivation {
  inherit pname version;
  dontUnpack = true;

  nativeBuildInputs = [
    nodejs_22
    makeWrapper
  ];

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

    # The tygo-generated TypeScript types are the only machine-readable
    # description of this API — upstream's DEVELOPMENT.md advertises Swagger at
    # /swagger, but there is no backend/docs, no @Router annotations, and the
    # route 404s. Ship them so hosts/rpi5/showmycards.nix can surface them at a stable
    # /etc path for the `showmycards` agent skill to read: request/response
    # shapes and the limit constants then track the pinned source automatically
    # instead of rotting in hand-written prose.
    install -Dm444 ${src}/frontend/src/lib/types/api.ts    $out/share/showmycards/api/api.ts
    install -Dm444 ${src}/frontend/src/lib/types/models.ts $out/share/showmycards/api/models.ts
    runHook postInstall
  '';

  meta = {
    description = "Self-hosted Magic: The Gathering collection manager (from source)";
    homepage = "https://showmy.cards";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
