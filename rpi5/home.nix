{
  config,
  lib,
  pkgs,
  inputs,
  username,
  ...
}:
{
  imports = [
    ./openclaw.nix
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";
  };

  # Disable zsh-auto-notify on the RPi5 (headless — no notify-send)
  programs.zsh.zplug.plugins = lib.mkForce [
    { name = "zsh-users/zsh-syntax-highlighting"; }
    { name = "spaceship-prompt/spaceship-prompt"; }
  ];
}
