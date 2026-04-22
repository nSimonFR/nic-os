{ pkgs, unstablePkgs, redisHost, redisPort, ... }:
{
  services.immich = {
    enable        = true;
    package       = unstablePkgs.immich;
    port          = 2283;
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
      MemoryMax = "512M";
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
}
