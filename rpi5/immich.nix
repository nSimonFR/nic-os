{ ... }:
{
  services.immich = {
    enable        = true;
    port          = 2283;
    host          = "127.0.0.1";  # force IPv4; Tailscale Serve proxies to 127.0.0.1
    mediaLocation = "/mnt/cloud/Photos";
    machine-learning.enable = false;  # disable the systemd unit, not just the runtime config flag
  };

  # filebrowser's tmpfiles rule sets /mnt/cloud to 0700 on every nixos-rebuild switch.
  # Override it with a z rule (which runs after the d rule since immich.nix is imported
  # after filebrowser.nix) so immich can read/write its mediaLocation inside /mnt/cloud.
  systemd.tmpfiles.rules = [ "z /mnt/cloud 0755 - - -" ];

  # Ensure Immich starts after /mnt/cloud is loop-mounted (mediaLocation lives there)
  systemd.services.immich-server.after = [ "storj-local-mount.service" ];
  systemd.services.immich-server.wants = [ "storj-local-mount.service" ];
}
