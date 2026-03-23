{ ... }:
{
  services.immich = {
    enable        = true;
    port          = 2283;
    # host defaults to 127.0.0.1 — Tailscale Serve owns TLS termination
    mediaLocation = "/var/lib/immich";
    machine-learning.enable = false;  # disable the systemd unit, not just the runtime config flag
  };

  # Ensure Immich starts after /mnt/cloud is loop-mounted (external library path)
  systemd.services.immich-server.after = [ "storj-local-mount.service" ];
  systemd.services.immich-server.wants = [ "storj-local-mount.service" ];
}
