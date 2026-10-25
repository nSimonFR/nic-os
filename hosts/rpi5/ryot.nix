# hosts/rpi5/ryot.nix
#
# Ryot V11 — the TypeScript rewrite (IgnisDa/ryot#1832, unreleased), run from the
# official arm64 image pinned by digest, inside systemd-nspawn. There is no
# container runtime on the Pi; nspawn runs the unpacked rootfs directly.
#
# Pinned on purpose: until the release, upstream regenerates its single Drizzle
# migration baseline (2026-10-18, 2026-10-24), so a V2 database cannot follow a
# newer pre-release image. Do not bump `image` until V11 ships.
#
# Fallback: the V1 database `ryot` is left untouched at cutover. `ryot-seed`
# copies it into `ryotv2` once, before V2's first start, and V2's startup
# migration converts that copy. Rolling back = revert this file (ryot-nix is
# still imported, just disabled) and V1 resumes on its own database.
#
# Tailnet-only on :3710. The client bundle hard-codes root paths (/assets,
# /api/auth, /oauth/login), so the /ryot/ sub-path V1 used on the 443 mux
# cannot work with a prebuilt image.
#
# The app runs as the image's uid 1001 (host: nsimon), confined to the
# container's mount and PID namespaces.
{ config, pkgs, lib, pgHost, pgPort, ... }:
let
  port      = 13350; # V2 binds 0.0.0.0; reachable on lo + tailscale0 only
  redisPort = 6380;
  stateDir  = "/var/lib/ryot-v2";
  envFile   = "/run/ryot-v2/env";

  image = pkgs.dockerTools.pullImage {
    imageName      = "ignisda/ryot";
    imageDigest    = "sha256:7e817e1399b53515240de4d124fea401e970481d66f933d666b6ab84b44a392e";
    hash           = "sha256-CbAToWxUT1SaKNj12Rmqm23LR8wcRXb8Fv4Kd6Ps1UA=";
    finalImageName = "ignisda/ryot";
    finalImageTag  = "pr-1832-7fc54de";
    os             = "linux";
    arch           = "arm64";
  };

  publicUrl = config.nic.services.ryot.public.publicUrl;

  # Unpacked as root so the setuid sandbox launcher and its root-owned trusted
  # paths survive; the Nix store can hold neither.
  prepareRootfs = pkgs.writeShellApplication {
    name = "ryot-v2-prepare-rootfs";
    runtimeInputs = [ pkgs.skopeo pkgs.umoci pkgs.coreutils ];
    text = ''
      marker=${stateDir}/rootfs.source
      if [ "$(cat "$marker" 2>/dev/null)" != "${image}" ]; then
        tmp=$(mktemp -d ${stateDir}/unpack.XXXXXX)
        skopeo --insecure-policy copy docker-archive:${image} "oci:$tmp/oci:img"
        umoci unpack --image "$tmp/oci:img" "$tmp/bundle"
        rm -rf ${stateDir}/rootfs
        mv "$tmp/bundle/rootfs" ${stateDir}/rootfs
        rm -rf "$tmp"
        echo "${image}" > "$marker"
      fi
      install -d -o 1001 -g 1001 -m 0750 ${stateDir}/storage
    '';
  };

  # Secrets go through a root-only file bound into the container, not
  # --setenv, which would put them on the command line.
  writeEnv = pkgs.writeShellApplication {
    name = "ryot-v2-env";
    runtimeInputs = [ pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
    text = ''
      umask 077
      v1() { grep -m1 "^$1=" /run/agenix/ryot-env | cut -d= -f2- | sed -E "s/^['\"]//; s/['\"]$//"; }
      q() { jq -rn --arg k "$1" --arg v "$2" '"\($k)=\($v | @sh)"'; }
      pw=$(jq -rn --rawfile p /run/agenix/ryot-pg-password '$p | rtrimstr("\n") | @uri')
      {
        q DATABASE_URL "postgres://ryot:$pw@${pgHost}:${toString pgPort}/ryotv2"
        q SERVER_ADMIN_ACCESS_TOKEN "$(v1 SERVER_ADMIN_ACCESS_TOKEN)"
        q RYOT_PLUGIN__RYOT__MEDIA__TMDB_ACCESS_TOKEN "$(v1 MOVIES_AND_SHOWS_TMDB_ACCESS_TOKEN)"
        q RYOT_PLUGIN__RYOT__MEDIA__SPOTIFY_CLIENT_ID "$(v1 MUSIC_SPOTIFY_CLIENT_ID)"
        q RYOT_PLUGIN__RYOT__MEDIA__SPOTIFY_CLIENT_SECRET "$(v1 MUSIC_SPOTIFY_CLIENT_SECRET)"
        q RYOT_PLUGIN__RYOT__MEDIA__TWITCH_CLIENT_ID "$(v1 VIDEO_GAMES_TWITCH_CLIENT_ID)"
        q RYOT_PLUGIN__RYOT__MEDIA__TWITCH_CLIENT_SECRET "$(v1 VIDEO_GAMES_TWITCH_CLIENT_SECRET)"
      } > ${envFile}
    '';
  };

  # One-time copy of V1 into ryotv2, built under a temporary name and renamed in
  # one step, so a failed copy never leaves a half-filled ryotv2 that later
  # starts would skip. Extensions are created as postgres first; ryot can't.
  seed = pkgs.writeShellApplication {
    name = "ryot-v2-seed";
    runtimeInputs = [ config.services.postgresql.package pkgs.gnugrep ];
    text = ''
      sql() { psql -X -q "$@"; }
      if sql -Atc "select 1 from pg_database where datname = 'ryotv2'" | grep -q 1; then
        exit 0
      fi
      sql -c "drop database if exists ryotv2_seed"
      sql -c "create database ryotv2_seed owner ryot"
      sql -d ryotv2_seed -c 'create extension if not exists "uuid-ossp"' -c 'create extension if not exists pg_trgm'
      { echo 'SET ROLE ryot;'; pg_dump --no-owner --no-acl --exclude-extension='*' ryot; } \
        | sql -v ON_ERROR_STOP=1 --single-transaction -d ryotv2_seed
      sql -c "alter database ryotv2_seed rename to ryotv2"
    '';
  };

  # nspawn mounts a fresh /run, so the sandbox lock the image's provision step
  # created at build time has to be recreated before dropping to uid 1001.
  inner = lib.concatStringsSep " && " [
    "install -d -o root -g root -m 0700 /run/ryot-sandboxd"
    "install -o root -g root -m 0600 /dev/null /run/ryot-sandboxd/.lock"
    "set -a" ". /etc/ryot.env" "set +a"
    "exec /usr/bin/setpriv --reuid=1001 --regid=1001 --clear-groups /usr/local/bin/bun run dist/main.js"
  ];
in
{
  # Shared by V1 (rollback source) and V2: same role and password.
  nic.pgRole.ryot = {
    db           = "ryot";
    user         = "ryot";
    passwordFile = "/run/agenix/ryot-pg-password";
    privateUsers = false;
  };

  # V1 stays importable for rollback; nothing of it runs.
  services.ryot.enable = false;

  # Dedicated Redis: V2's job queue (BullMQ) needs noeviction, and the shared
  # instance runs allkeys-lru (databases.nix).
  services.redis.servers.ryot-v2 = {
    enable = true;
    bind = "127.0.0.1";
    port = redisPort;
    settings = {
      maxmemory = "64mb";
      maxmemory-policy = "noeviction";
    };
  };

  systemd.services.ryot-seed = {
    description = "Ryot V2: one-time copy of the V1 database";
    after = [ "postgresql.service" "ryot-pg-setup.service" ];
    requires = [ "postgresql.service" "ryot-pg-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      ExecStart = lib.getExe seed;
    };
  };

  systemd.services.ryot = {
    description = "Ryot V11 (pinned pre-release image in systemd-nspawn)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "ryot-seed.service" "redis-ryot-v2.service" ];
    wants = [ "network-online.target" ];
    requires = [ "ryot-seed.service" "redis-ryot-v2.service" ];
    serviceConfig = {
      StateDirectory = "ryot-v2";
      RuntimeDirectory = "ryot-v2";
      RuntimeDirectoryMode = "0700";
      ExecStartPre = [ (lib.getExe prepareRootfs) (lib.getExe writeEnv) ];
      ExecStart = lib.escapeShellArgs [
        "${config.systemd.package}/bin/systemd-nspawn"
        "--quiet" "--register=no" "--keep-unit"
        "--directory=${stateDir}/rootfs"
        "--chdir=/home/ryot"
        "--bind-ro=${envFile}:/etc/ryot.env"
        "--bind=${stateDir}/storage:/home/ryot/storage"
        "--setenv=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "--setenv=HOME=/home/ryot"
        "--setenv=NODE_ENV=production"
        "--setenv=PORT=${toString port}"
        "--setenv=REDIS_URL=redis://127.0.0.1:${toString redisPort}/0"
        "--setenv=FRONTEND_URL=${publicUrl}"
        "--setenv=USERS_ALLOW_REGISTRATION=false"
        "--setenv=DISABLE_TELEMETRY=true"
        "--setenv=FILE_STORAGE_LOCAL_DIR=/home/ryot/storage"
        "--setenv=FILE_STORAGE_LOCAL_TEMP_DIR=/home/ryot/tmp"
        "--setenv=SANDBOX_WORKER_CONCURRENCY=1"
        "--setenv=SANDBOX_IMPORT_CONCURRENCY=1"
        "/bin/sh" "-c" inner
      ];
      KillMode = "mixed";
      Restart = "always";
      RestartSec = 15;
      # First start runs the V1→V2 conversion (~70 s here) before listening.
      TimeoutStartSec = "10min";
    };
  };

  # V2 mints API keys only for a signed-in user and V1 keys don't migrate, so
  # this gives the account a password and writes a key for the local services
  # (connectors, scale shim, Agent Vault). The password lands in
  # ${stateDir}/secrets/password for the user's own sign-in.
  users.groups.ryot-api = { };
  systemd.tmpfiles.rules = [ "d ${stateDir}/secrets 0750 root ryot-api -" ];

  systemd.services.ryot-bootstrap = {
    description = "Ryot V2: ensure an API key for local services";
    wantedBy = [ "ryot.service" ];
    after = [ "ryot.service" ];
    bindsTo = [ "ryot.service" ];
    environment = {
      RYOT_URL = "http://127.0.0.1:${toString port}";
      RYOT_FRONTEND_URL = publicUrl;
      SECRETS_DIR = "${stateDir}/secrets";
    };
    path = [ pkgs.util-linux config.services.postgresql.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = envFile; # SERVER_ADMIN_ACCESS_TOKEN
      ExecStart = "${pkgs.nicos-scripts}/bin/ryot-bootstrap";
    };
  };

  # A new key has to reach the broker; its bootstrap reads it as an optional credFile.
  systemd.paths.ryot-api-key = {
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = "${stateDir}/secrets/api-key";
  };
  systemd.services.ryot-api-key = {
    description = "Re-apply Agent Vault credentials after a new Ryot key";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${config.systemd.package}/bin/systemctl try-restart agent-vault-bootstrap.service";
    };
  };

  nic.services.ryot = {
    backup            = [ "postgres" ];
    # `ryot` stays backed up while it is the rollback source.
    postgresDatabases = [ "ryotv2" "ryot" ];
    heavyUnits        = [ "ryot.service" ];
    heavyPriority     = 90;

    public = {
      order   = 120;
      port    = 3710;
      backend = "http://127.0.0.1:${toString port}";
      funnel  = false;
      authenticated = true;
      tile = {
        name        = "Ryot";
        icon        = "ryot.svg";
        category    = "Apps";
        description = "Media & life tracker";
        # homepage-stats reads ryotv2 directly; see RYOT_MEDIA_HOURS_SQL.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/ryot";
          refreshInterval = 3600000;
          mappings = [
            { field = "seen";     label = "Media seen"; format = "number"; }
            { field = "hours";    label = "Hours seen"; format = "number"; suffix = "h"; }
            { field = "workouts"; label = "Workouts";   format = "number"; }
          ];
        };
      };
    };
  };
}
