# nic-clip — a CLIP content filter for Immich Workflows.
#
# Immich 3.1 has a real workflow engine, and immich.nix already uses it (the
# `Auto-file screenshots` workflow). What the bundled `immich-plugin-core` cannot
# do is filter on what is IN a picture: its filters are filename, EXIF, type,
# date, location and missing-timezone. This module adds that missing step:
#
#   AssetMetadataExtraction -> nic-clip#clipFilter(profile=food, albumIds=[Food])
#
# ⚠️ ONE step, deliberately. `WorkflowRepository.getForWorkflowRun` selects
# workflow_step with no `ORDER BY "order"`, so Postgres returns the steps in
# whatever order it likes — the same query was observed returning
# [typeFilter, addToAlbums, clipFilter] on one call and the declared order on the
# next. When the add lands first, EVERY asset is filed regardless of the verdict.
# So the filter cannot be chained ahead of `assetAddToAlbums`; it does the type
# check and the album add itself. (The pre-existing `Auto-file screenshots`
# workflow has the same exposure and has simply been lucky.)
#
# Two halves, because one of them cannot do the job alone:
#
#   * the WASM plugin (../immich-clip, built by pkgs/services/immich-clip-plugin.nix)
#     runs inside Immich, but its only way out is the `httpRequest` host function,
#     which returns `body: await res.text()`. No image bytes fit through that, so
#     it cannot call CLIP itself;
#   * the sidecar below answers the question instead — and answers it from the
#     embeddings Immich has ALREADY computed on beast (`smart_search.embedding`)
#     rather than running a second inference pass. That means no duplicate GPU
#     work and no decoding HEIC originals on the Pi.
#
# The cost of that choice is honest and worth stating: a freshly uploaded asset
# is not embedded yet, so the step waits (bounded) and treats "still not ready"
# as no-match. Nothing retries it automatically. `immich-clip-backfill` is the
# manual catch-up, and also how the threshold gets calibrated in the first place.
{ config, lib, pkgs, ... }:

let
  port = 8351;
  sidecarUrl = "http://127.0.0.1:${toString port}/classify";
  stateDir = "/var/lib/immich-clip";
  profileDir = "${stateDir}/profiles";

  # Single consumer (this module), so it stays a callPackage at the use site
  # rather than an entry in pkgs/overlay.nix — see the rule at the top of that file.
  plugin = pkgs.callPackage ../../pkgs/services/immich-clip-plugin.nix {
    src = ./immich-clip;
    inherit sidecarUrl;
  };

  # Only the three immich-clip-* console scripts, so enabling this feature does
  # not put all fifteen of nicos-scripts' entry points on every shell's PATH.
  clipTools = pkgs.symlinkJoin {
    name = "immich-clip-tools";
    paths = [ pkgs.nicos-scripts ];
    postBuild = ''
      find $out/bin -mindepth 1 -maxdepth 1 ! -name 'immich-clip-*' -delete
    '';
  };
in
{
  # Immich reads plugins from subdirectories of this folder at boot, on the
  # microservices worker. `environment` is a freeform attrsOf str and NixOS merges
  # it across modules, so the whole feature stays in this file and immich.nix is
  # left alone.
  services.immich.environment = {
    IMMICH_ALLOW_EXTERNAL_PLUGINS = "true";
    IMMICH_PLUGINS_INSTALL_FOLDER = "${plugin}";
  };

  # ── The verdict sidecar ─────────────────────────────────────────────────────
  # Runs as `immich` for one reason: pg_hba's `local all all peer` then lets it
  # read smart_search over the unix socket with no password and no new role.
  systemd.services.immich-clip-filter = {
    description = "CLIP filter sidecar for the Immich nic-clip workflow step";
    wantedBy = [ "multi-user.target" ];
    after = [ "postgresql.service" "network.target" ];
    wants = [ "postgresql.service" ];

    environment = {
      LISTEN_ADDR = "127.0.0.1";
      LISTEN_PORT = toString port;
      IMMICH_PG_DB = "immich";
      IMMICH_CLIP_PROFILE_DIR = profileDir;
      # Derived, never typed twice: a centroid built against one CLIP model is
      # meaningless under another, and the sidecar refuses a profile whose
      # recorded model does not match this.
      IMMICH_CLIP_MODEL = config.services.immich.settings.machineLearning.clip.modelName;
      # Ceiling on what a workflow step may ask to wait for. The workflow queue
      # runs 5 jobs and the extism plugin pool holds 5 — an unbounded wait in a
      # config box could pin all of them during an import.
      IMMICH_CLIP_MAX_WAIT = "120";
      IMMICH_CLIP_POLL_SEC = "2";
    };

    serviceConfig = {
      User = "immich";
      Group = "immich";
      ExecStart = "${pkgs.nicos-scripts}/bin/immich-clip-filter";
      Restart = "on-failure";
      RestartSec = 5;

      StateDirectory = "immich-clip";
      StateDirectoryMode = "0750";

      # Loopback-only JSON service that reads one table and some JSON files.
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      SystemCallArchitectures = "native";
    };
  };

  # `sudo -u immich immich-clip-profile --name food --seed-album "Burgiiiiiiie"`
  # `sudo -u immich immich-clip-backfill --profile food --album Food`
  # Both need to be the immich user for the same peer-auth reason as the sidecar.
  environment.systemPackages = [ clipTools ];

  # The profile directory is created by the sidecar's StateDirectory, but the
  # by-hand tools may run before the service has ever started.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 immich immich -"
    "d ${profileDir} 0750 immich immich -"
  ];

  nic.services.immich-clip = {
    backup = [ "none" ];
    backupNote = ''
      Only a CLIP centroid cache in ${profileDir}. Every profile is rebuilt from
      its recorded seed album or prompt with immich-clip-profile, and the
      embeddings it is derived from live in the immich database, which Immich's
      own backup covers. Nothing here is a source of truth.
    '';
  };
}
