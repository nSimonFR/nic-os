# FreeReps — self-hosted Apple Health server (github.com/meltforce/FreeReps, MIT).
#
# Upstream ships only a docker-compose stack (a `timescale/timescaledb` image +
# `meltforce/freereps`). This builds the same thing natively: one Go binary with
# the React dashboard baked in, against the rpi5's existing Postgres cluster.
#
# The iPhone side is NOT built here — it is the free App Store app
# (apps.apple.com/app/id6760661354), which takes an arbitrary host+port, so it
# talks to whatever origin hosts/rpi5/freereps.nix declares.
#
# ── Two-stage build ──────────────────────────────────────────────────────────
# `server/web.go` is `//go:embed all:web/dist`, and `.gitignore` excludes
# `server/web/dist` — so the checkout has no `dist` and the Go compile fails
# outright without one. `frontend` below produces it and `preBuild` drops it in
# place before the embed is resolved. That ordering is load-bearing, not tidiness.
#
# ⚠ THREE HASHES, all content hashes of fetched inputs, all of which move when
#   `rev` moves: `src.hash`, `frontend.npmDepsHash`, `vendorHash`. Renovate
#   cannot recompute any of them (reference_renovate_nix_pins). Set the changed
#   one to lib.fakeHash, build once, paste the reported `got: sha256-…`. They
#   surface in that order — src first, then the two dependency sets.
#
#   Unlike showmycards.nix's per-arch npm FODs, `npmDepsHash` here is ONE value
#   across aarch64 and x86_64: buildNpmPackage walks package-lock.json with
#   prefetch-npm-deps, which downloads every entry regardless of its os/cpu
#   field. The lockfile does carry the linux-arm64-gnu binaries for oxide,
#   rollup and lightningcss, which is what makes the aarch64 build work at all.
{
  lib,
  fetchFromGitHub,
  buildGoModule,
  buildNpmPackage,
  nodejs_22,
}:

let
  # Upstream has cut no tags — pinned to a commit, hence the nixpkgs
  # "unstable" version convention. Bump `rev` and the date together.
  version = "0-unstable-2026-08-10";

  src = fetchFromGitHub {
    owner = "meltforce";
    repo = "FreeReps";
    rev = "d50316d835f84f263c81f4a7fb7268ae26bfe11f";
    # An FOD's store path is keyed on (outputHash, name), NOT on what it
    # fetched, and fetchFromGitHub defaults name="source". Without a
    # version-bearing name, moving `rev` while forgetting the hash silently
    # re-serves the OLD tree. See known_issue_nix_fod_hash_desync — that trap
    # shipped sure-0.7.3 as v0.7.2.
    name = "freereps-${version}-source";
    hash = "sha256-liQ87Qd0WQkbF0If/T4clQJgZMUonV2BU0HDKSby5uM=";
  };

  # React 19 + Vite 6 + Tailwind 4. Output is a plain directory of static
  # assets; nothing here runs at runtime, it all ends up inside the Go binary.
  frontend = buildNpmPackage {
    pname = "freereps-web";
    inherit version src;
    sourceRoot = "${src.name}/server/web";

    npmDepsHash = "sha256-jjZ7fchjmFpazvH/uB7ojPPqDsjYLX/xqa2HBp9TKx0=";

    nodejs = nodejs_22;
    npmBuildScript = "build"; # tsc -b && vite build

    # Vite/Rollup are memory-hungry and this box has ~600 MB free with earlyoom
    # armed; cap the heap so it leans on swap instead of being killed (same
    # guard as showmycards.nix and airtrail-nix).
    env.NODE_OPTIONS = "--max-old-space-size=2048";

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R dist $out/dist
      runHook postInstall
    '';
  };

in
buildGoModule {
  pname = "freereps";
  inherit version src;

  modRoot = "server";
  vendorHash = "sha256-EdxUn7JYGaxs8PqiLqAtQqw1MFKGivvxwRB0rNelUAA=";

  # cmd/freereps-upload is a dev helper for replaying exports by hand; the
  # server binary carries the MCP mode (-mcp) and the migrator (-migrate-only).
  subPackages = [ "cmd/freereps" ];

  ldflags = [
    "-s"
    "-w"
    "-X"
    "main.Version=${version}"
  ];

  # pgx defaults its pool to numCPU, but db.go hardcodes `cfg.MaxConns = 16`.
  # The rpi5 runs ONE shared Postgres with max_connections = 60 (databases.nix)
  # that Immich alone holds ~19 idle connections against, and each backend cost
  # 17–23 MB RSS when measured on this box. 16 more is a quarter of the
  # cluster's connection budget and ~240 MB for a single-user health dashboard.
  # MinConns is 0, so this only ever bites under concurrent load — which is
  # exactly when the box can least afford it.
  postPatch = ''
    substituteInPlace server/internal/storage/db.go \
      --replace-fail 'cfg.MaxConns = 16' 'cfg.MaxConns = 4'
  '';

  # buildGoModule cd's into $modRoot during configurePhase, so cwd is already
  # `server` here — which is exactly where web.go expects `web/dist`.
  preBuild = ''
    mkdir -p web/dist
    cp -R ${frontend}/dist/. web/dist/
  '';

  # The vendor FOD is built from the SAME attrs as the main derivation (that is
  # what overrideModAttrs exists for), so it inherits `preBuild` above and would
  # take a dependency on the entire Vite build just to run `go mod download`.
  # Worse, it makes a frontend failure surface as "go-modules: 1 dependency
  # failed", which is where the vendorHash bring-up actually got stuck. Drop it.
  overrideModAttrs = _: { preBuild = null; };

  # `RunMigrations(dsn, "migrations")` (internal/storage/db.go) resolves a
  # RELATIVE path, so the migrations have to sit next to a WorkingDirectory the
  # unit can point at. hosts/rpi5/freereps.nix sets
  # WorkingDirectory=${freereps}/share/freereps for exactly this.
  postInstall = ''
    mkdir -p $out/share/freereps
    cp -R ${src}/server/migrations $out/share/freereps/migrations
  '';

  # `go test ./...` needs a live TimescaleDB for the storage suite (see
  # server/Makefile's separate `test-integration` target, and the plain `test`
  # target still touches internal/storage). Not worth a service container in
  # the sandbox on a 4 GB box.
  doCheck = false;

  meta = {
    description = "Self-hosted Apple Health data server with dashboard and MCP interface";
    homepage = "https://github.com/meltforce/FreeReps";
    license = lib.licenses.mit;
    mainProgram = "freereps";
    platforms = lib.platforms.linux;
  };
}
