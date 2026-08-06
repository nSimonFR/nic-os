# The baseline both NixOS hosts share.
#
# BeAsT and rpi5 are a gaming desktop and a headless server and have almost
# nothing in common — but "almost nothing" was still fifteen blocks stated twice,
# and stating a thing twice is how it drifts. This module holds only the parts
# that are genuinely host-agnostic; anything a host legitimately tunes is left at
# the host, either because it isn't declared here at all or because it's declared
# with `lib.mkDefault` for the host to override.
#
# The rule for adding something here: it must be true of *any* NixOS host we'd
# ever run, not just true of both hosts today. `nix.gc.options` (30d on BeAsT, 7d
# on the Pi) and the journald caps are deliberate consequences of disk size, so
# they stay host-local. `time.timeZone` is not.
#
# macOS (hosts/nbookpro/configuration.nix) deliberately does NOT import this: nix-darwin's
# option set only partially overlaps NixOS's, so the shared-looking options
# (`services.openssh`, `zramSwap`, `i18n`, `users.users.*.isNormalUser`) either
# don't exist or mean something different there. Follow shared/tailscale.nix's
# precedent — shared by the hosts that can actually share it, not by all three.
{
  lib,
  pkgs,
  username,
  hostname,
  ...
}:
{
  # `hostname` was a specialArg on all three system configs with exactly one
  # consumer (hosts/nbookpro/configuration.nix); both NixOS hosts swallowed it in `...`
  # and hardcoded their own name. Use the argument.
  networking.hostName = hostname;

  nixpkgs.config.allowUnfree = true;

  time.timeZone = "Europe/Paris";
  i18n.defaultLocale = "en_US.UTF-8";

  # zsh as the login shell. `programs.zsh.enable` is what puts it in
  # /etc/shells, which `users.defaultUserShell` needs to be honoured.
  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  services.openssh.enable = true;
  services.resolved.enable = true;

  programs.gnupg.agent = {
    enable = true;
    pinentryPackage = pkgs.pinentry-curses;
    # The Pi turns this on (it is the box that signs from headless sessions);
    # BeAsT keeps the Bitwarden desktop agent instead.
    enableSSHSupport = lib.mkDefault false;
  };

  # The primary user's identity. Group membership is host-specific (BeAsT needs
  # video/i2c/libvirtd/…, the Pi needs nextcloud) and stays at the host — this is
  # only the part that would otherwise be restated.
  users.users.${username} = {
    isNormalUser = true;
    home = "/home/${username}";
    # This literal used to appear in four files. `openssh.authorizedKeys.keys` is
    # a list option, so a host that needs an extra key appends it rather than
    # restating this one.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ7wzLFXmWeZ52SWjvsfXSZr+LbvpZYt/EE/tzVZnFd"
    ];
  };

  # Compressed swap. Sizing and algorithm are per-host (32 GB of DDR4 and 4 GB of
  # LPDDR4X want different answers) and stay at the host.
  zramSwap.enable = lib.mkDefault true;

  # Both hosts were installed on 25.11. This is a per-host fact that happens to
  # coincide, hence mkDefault rather than a flat assignment — a host installed on
  # a later release sets its own and must never inherit one.
  system.stateVersion = lib.mkDefault "25.11";

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    # `options` is host-local: the retention window is a function of free disk.
  };
}
