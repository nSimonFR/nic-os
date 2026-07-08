# Immich machine-learning (CLIP + face recognition) — NATIVE, GPU-accelerated
# on beast's RTX 3080 Ti. No container, no virtualisation: the ML worker runs
# as a plain systemd service built from nixpkgs with a CUDA onnxruntime,
# mirroring the ollama-cuda pattern (see services.ollama in configuration.nix).
#
# The rpi5 runs the Immich *server* but no local ML (see rpi5/immich.nix); it
# points IMMICH_MACHINE_LEARNING_URL at this host over the tailnet. Running the
# heavy ViT-H-14-378 CLIP model here on the 3080 Ti gives far better search
# (French, text-in-image, rare subjects) than the rpi5's tiny default model.
#
# Why a standalone unit and NOT services.immich.machine-learning: the NixOS
# immich module couples ML to the full server (postgres + redis + server unit)
# behind a single `mkIf cfg.enable`, and hardens the ML unit with
# PrivateDevices=true — which hides /dev/nvidia* and kills GPU access. We only
# want the ML worker with the GPU, so we run the package's `machine-learning`
# binary (gunicorn → immich_ml.main:app) directly.
#
# Why native and not the official -cuda container: the previous iteration used
# virtualisation.oci-containers + nvidia-container-toolkit; this replaces that
# with a first-class Nix build. config.cudaSupport propagates transitively
# through onnxruntime → CUDAExecutionProvider (immich-ml itself has no CUDA
# flag), exactly like ollama-cuda. ⚠️ Building onnxruntime-cuda is a heavy,
# mostly-from-source compile (not in cache.nixos.org) — expect a long first
# build on beast; subsequent rebuilds are cached in the nix store.
#
# ⚠️ VERSION LOCK-STEP — Immich requires ML version == server version. Both are
# driven by the shared `immichVersion` from flake.nix (derived from the rpi5's
# nixpkgs-unstable immich), so they cannot silently drift. The assertion below
# fails the build loudly if the resolved package ever disagrees.
{
  inputs,
  lib,
  immichVersion,
  ...
}:
let
  mlPort = 3003;

  # CUDA-enabled immich-machine-learning, same import pattern as ollama-cuda.
  # config.cudaSupport = true flows through onnxruntime and gives the ML worker
  # a CUDAExecutionProvider; without it nixpkgs builds onnxruntime CPU-only.
  immichMlCuda =
    (import inputs.nixpkgs-unstable {
      system = "x86_64-linux";
      config.allowUnfree = true;
      config.cudaSupport = true;
    }).immich-machine-learning;
in
{
  # Guard the server==ML lock-step. immichVersion (flake.nix) is derived from
  # the same nixpkgs-unstable as this package, so a mismatch means something
  # drifted — fail the build rather than break ML silently at runtime.
  assertions = [
    {
      assertion = immichMlCuda.version == immichVersion;
      message =
        "immich-ml (${immichMlCuda.version}) != shared immichVersion (${immichVersion}); "
        + "Immich requires the ML worker and server to be the same version.";
    }
  ];

  systemd.services.immich-machine-learning = {
    description = "Immich machine learning (CLIP + faces) — CUDA on the RTX 3080 Ti";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    environment = {
      # Bind all interfaces — reachable only over tailscale0 (a trusted firewall
      # interface, see shared/tailscale.nix) + localhost; no port is opened for
      # other interfaces. Same posture as ollama. The rpi5 reaches it over the
      # tailnet at ${beastHost}:3003. (The package reads IMMICH_HOST/IMMICH_PORT.)
      IMMICH_HOST = "0.0.0.0";
      IMMICH_PORT = toString mlPort;
      # Model cache (~2-4 GB downloads) persisted via CacheDirectory below.
      MACHINE_LEARNING_CACHE_FOLDER = "/var/cache/immich-ml";
      XDG_CACHE_HOME = "/var/cache/immich-ml";
      # Evict the model from VRAM after 5 min idle. Secondary safety — the
      # gamemode stop hook (configuration.nix) is the primary VRAM-freeing
      # mechanism during gameplay.
      MACHINE_LEARNING_MODEL_TTL = "300";
    };

    serviceConfig = {
      ExecStart = lib.getExe immichMlCuda;
      # Dedicated ephemeral user; the model cache survives restarts because
      # CacheDirectory is managed by systemd (owned by the DynamicUser).
      DynamicUser = true;
      CacheDirectory = "immich-ml"; # → /var/cache/immich-ml
      Restart = "on-failure";
      RestartSec = 5;
      # NB: deliberately NOT hardened with PrivateDevices — the worker needs the
      # /dev/nvidia* nodes (world-readable under the proprietary driver) to reach
      # the GPU. hardware.graphics + hardware.nvidia expose libcuda via the
      # global driver runpath; onnxruntime's CUDA libs are RPATH-baked (no
      # LD_LIBRARY_PATH needed).
    };
  };
}
