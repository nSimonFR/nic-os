# Wealthfolio — private investment/portfolio tracker (wealthfolio/wealthfolio).
#
# WHY THE UPSTREAM IMAGE AND NOT A SOURCE BUILD:
# the server half of Wealthfolio is a single Axum binary (`apps/server`, SQLite
# via diesel) plus a static React `dist/`. Building it here means ~910 Rust
# crates — including aws-lc-sys, which needs cmake + bindgen — followed by a
# pnpm/Turborepo frontend, on a 3.9 GB Pi. beast cannot take the load off: it is
# x86_64 and this is the only aarch64 box.
#
# Upstream's release assets ship a server tarball for linux-amd64 ONLY, so on
# aarch64 the multi-arch container image is the sole prebuilt artifact. What it
# holds is unusually well-behaved for our purposes: `wealthfolio-server` is a
# STATICALLY LINKED musl binary (`file` reports "statically linked", confirmed
# on the Pi before this was written), so it runs on NixOS untouched — no
# patchelf, no interpreter fixup, no LD_LIBRARY_PATH. We take the binary and
# the prebuilt dist out of the image and drop the rest of the Alpine rootfs.
#
# BUMPING: change `version` AND the matching `imageDigest`/`hash` below, then
# rebuild. The digest is per-architecture; get a new one with
#
#   skopeo inspect --raw docker://docker.io/wealthfolio/wealthfolio:<version> \
#     | jq -r '.manifests[]|select(.platform.architecture=="arm64")|.digest'
#
# pullImage is a fixed-output derivation, and an FOD path is keyed on (hash,
# name) — NOT on what it fetched. `finalImageTag = version` is therefore
# load-bearing: it puts the version in the store path's name, so bumping
# `version` while forgetting the digest changes the name and forces a refetch
# instead of silently reusing the old image under a new version number. That is
# the same trap that shipped sure-0.7.3 as v0.7.2 for a day.
{
  lib,
  stdenvNoCC,
  dockerTools,
  gnutar,
  jq,
}:
let
  version = "3.6.3";

  # docker.io/wealthfolio/wealthfolio:3.6.3, per-arch manifest digests.
  # `latest` pointed at these same digests when this was pinned.
  images = {
    aarch64-linux = {
      arch = "arm64";
      imageDigest = "sha256:71507bb82daccc0fe5bca1ab84cc000bc10dd60e778ffd78044a3a8605e3a817";
      hash = "sha256-x1UTAjQ+hj99yBmYL7jtXnH1mbePII5R/HGS/O45H70=";
    };
  };

  system = stdenvNoCC.hostPlatform.system;

  image =
    let
      spec =
        images.${system} or (throw "wealthfolio: no pinned image digest for ${system}; add one to pkgs/services/wealthfolio.nix");
    in
    dockerTools.pullImage {
      imageName = "wealthfolio/wealthfolio";
      finalImageName = "wealthfolio";
      finalImageTag = version;
      inherit (spec) imageDigest arch hash;
      os = "linux";
    };
in
stdenvNoCC.mkDerivation {
  pname = "wealthfolio";
  inherit version;

  src = image;
  dontUnpack = true;

  nativeBuildInputs = [
    gnutar
    jq
  ];

  # pullImage hands back a docker-archive tarball: manifest.json names the layer
  # tars in apply order. Walk them in that order so a file replaced by a later
  # layer wins, the same way a runtime would stack them.
  installPhase = ''
    runHook preInstall

    mkdir -p image rootfs
    tar -xf "$src" -C image

    for layer in $(jq -r '.[0].Layers[]' image/manifest.json); do
      tar -xf "image/$layer" -C rootfs
    done

    if [ ! -f rootfs/usr/local/bin/wealthfolio-server ]; then
      echo "wealthfolio: image ${version} has no usr/local/bin/wealthfolio-server" >&2
      exit 1
    fi
    if [ ! -f rootfs/app/dist/index.html ]; then
      echo "wealthfolio: image ${version} has no app/dist/index.html" >&2
      exit 1
    fi

    install -Dm755 rootfs/usr/local/bin/wealthfolio-server "$out/bin/wealthfolio-server"

    # The server serves the SPA itself, from WF_STATIC_DIR (default "dist",
    # relative to CWD — the module points at this path explicitly).
    mkdir -p "$out/share/wealthfolio"
    cp -r rootfs/app/dist "$out/share/wealthfolio/dist"

    runHook postInstall
  '';

  # The binary is static musl: nothing to patch, and autoPatchelf would only get
  # in the way. Stripping is skipped for the same reason — it buys ~nothing here
  # and risks touching a binary we did not build.
  dontStrip = true;
  dontPatchELF = true;

  passthru = { inherit image; };

  meta = {
    description = "Private, open-source investment and portfolio tracker (server edition)";
    homepage = "https://wealthfolio.app/";
    license = lib.licenses.agpl3Only;
    mainProgram = "wealthfolio-server";
    platforms = lib.attrNames images;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
