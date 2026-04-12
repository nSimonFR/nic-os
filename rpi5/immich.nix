{ pkgs, unstablePkgs, ... }:
{
  services.immich = {
    enable        = true;
    package       = unstablePkgs.immich;
    port          = 2283;
    host          = "127.0.0.1";
    mediaLocation = "/mnt/data/immich";
    machine-learning.enable = true;
  };

  # Ensure Immich starts after HDD is mounted.
  systemd.services.immich-server = {
    after = [ "mnt-data.mount" ];
    wants = [ "mnt-data.mount" ];
    serviceConfig.ExecStartPre = [
      "+${pkgs.coreutils}/bin/chown immich:immich /mnt/data/immich"
    ];
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

  systemd.services.immich-machine-learning.environment = {
    MACHINE_LEARNING_MODEL_TTL = "60";
    MACHINE_LEARNING_REQUEST_THREADS = "2";
  };
}
