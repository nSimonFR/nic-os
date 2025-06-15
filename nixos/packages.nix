{ config, pkgs, inputs, ... }:
{
  home.packages = with pkgs; [
    _1password-gui
    cliphist
    code-cursor
    dconf
    (discord.override {
      withOpenASAR = true;
      withVencord = true;
    })
    docker
    dunst
    eww
    kitty
    lxqt.lxqt-policykit
    pavucontrol
    pipewire
    inputs.quickshell.packages.${pkgs.system}.default
    rofi
    slack
    spotify
    wireplumber
  ];
} 