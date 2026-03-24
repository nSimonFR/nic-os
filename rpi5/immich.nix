{ pkgs, ... }:
{
  services.immich = {
    enable        = true;
    port          = 2283;
    host          = "127.0.0.1";  # force IPv4; Tailscale Serve proxies to 127.0.0.1
    mediaLocation = "/mnt/cloud/Photos";
    machine-learning.enable = true;
  };

  # filebrowser's tmpfiles rule sets /mnt/cloud to 0700 on every nixos-rebuild switch.
  # Override it with a z rule (which runs after the d rule since immich.nix is imported
  # after filebrowser.nix) so immich can read/write its mediaLocation inside /mnt/cloud.
  systemd.tmpfiles.rules = [ "z /mnt/cloud 0755 - - -" ];

  # Ensure Immich starts after /mnt/cloud is loop-mounted (mediaLocation lives there).
  # ExecStartPre chowns the mediaLocation to the immich user so it can create its
  # subdirectory structure (the directory is root:root after mkfs/storj restore).
  systemd.services.immich-server = {
    after = [ "storj-local-mount.service" ];
    wants = [ "storj-local-mount.service" ];
    serviceConfig.ExecStartPre = [
      "+${pkgs.coreutils}/bin/chown immich:immich /mnt/cloud/Photos"
    ];
  };

  # Reduce ML service memory footprint on RPi5:
  # - MODEL_TTL: unload models from RAM after 60s idle (default 300s)
  # - REQUEST_THREADS: cap inference threads to 2 (prevents CPU spike on all 4 cores)
  systemd.services.immich-machine-learning.environment = {
    MACHINE_LEARNING_MODEL_TTL = "60";
    MACHINE_LEARNING_REQUEST_THREADS = "2";
  };
}
