{ pkgs, unstablePkgs, redisHost, redisPort, ... }:
let
  # externalPort: where mobile/web clients reach Immich (Tailscale Funnel
  # terminates :10000 → http://127.0.0.1:2283). backendPort: where Immich
  # actually binds, behind the socket-activate proxy.
  externalPort = 2283;
  backendPort  = 2284;
in
{
  services.immich = {
    enable        = true;
    package       = unstablePkgs.immich;
    port          = backendPort;
    host          = "127.0.0.1";
    mediaLocation = "/mnt/data/immich";
    machine-learning.enable = true;

    # Use the shared Redis (databases.nix) on DB 1 via TCP instead of a
    # dedicated redis-immich instance. Saves ~7 MB RAM + one systemd unit.
    redis = {
      enable = false;
      host   = redisHost;
      port   = redisPort;
    };
    environment.REDIS_DBINDEX = "1";
  };

  # Ensure Immich starts after HDD is mounted.
  systemd.services.immich-server = {
    after = [ "mnt-data.mount" ];
    wants = [ "mnt-data.mount" ];
    environment.MALLOC_ARENA_MAX = "2";
    serviceConfig = {
      ExecStartPre = [
        "+${pkgs.coreutils}/bin/chown immich:immich /mnt/data/immich"
      ];
      # NestJS module init has a brief spike past steady-state RSS; the
      # extra headroom prevents the cgroup OOMing the process mid-boot
      # (cold-start now happens per socket-activate wake, not just at boot).
      MemoryMax = "768M";
    };
  };

  systemd.tmpfiles.rules = [
    "d /mnt/data/immich 0750 immich immich -"
    # SSD-backed dirs for fast access (bind-mounted from /var/lib/immich)
    "d /var/lib/immich/thumbs 0750 immich immich -"
    "d /var/lib/immich/encoded-video 0750 immich immich -"
    "d /var/lib/immich/profile 0750 immich immich -"
    "d /var/lib/immich/backups 0750 immich immich -"
  ];

  # Bind SSD dirs into the HDD mediaLocation so immich finds them there.
  # library + upload stay on HDD; thumbs, encoded-video, profile, backups on SSD.
  systemd.mounts = map (sub: {
    where = "/mnt/data/immich/${sub}";
    what = "/var/lib/immich/${sub}";
    type = "none";
    options = "bind";
    wantedBy = [ "local-fs.target" ];
  }) [ "thumbs" "encoded-video" "profile" "backups" ];

  systemd.services.immich-machine-learning = {
    environment = {
      MACHINE_LEARNING_MODEL_TTL = "60";
      MACHINE_LEARNING_REQUEST_THREADS = "1";
      MALLOC_ARENA_MAX = "2";
    };
    serviceConfig.MemoryMax = "1G";
  };

  # ── Socket-activated idle sleep (rpi5/lib/socket-activate.nix) ──────────
  # Immich is the first Funnel-exposed service in the socket-activate set:
  # idleSec=1800 (not 600) dampens wake noise from public bot probes hitting
  # the :10000 funnel URL. ML stops alongside the API tier (sleepWith) —
  # it's request-driven from immich-server's microservices worker_thread
  # and has nothing to do while the API is asleep. BullMQ jobs queue in
  # Redis and resume on wake; @nestjs/schedule cron ticks (NightlyJobs,
  # VersionCheck, LibraryScan) that fall in the asleep window are missed
  # and fire on the next wake instead — all idempotent.
  services.socketActivate.immich = {
    enable    = true;
    realUnit  = "immich-server.service";
    listen    = [ "127.0.0.1:${toString externalPort}" ];
    backend   = "127.0.0.1:${toString backendPort}";
    idleSec   = 1800;
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/api/server/ping";
      expectStatus = 200;
      timeoutSec   = 60;
    };
    workers."immich-machine-learning.service".policy = "sleepWith";
  };
}
