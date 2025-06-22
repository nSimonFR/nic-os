{ config, pkgs, inputs, unstablepkgs, ... }:
{
  home.packages = with pkgs; [
    _1password-gui
    alacritty
    cliphist
    code-cursor
    dconf
    (discord.override {
      withOpenASAR = true;
      withVencord = true;
    })
    docker
    dualsensectl
    dunst
    unstablepkgs.gamescope
    hypridle
    hyprlock
    hyprshot
    hyprsunset
    kubernetes-helm
    lxqt.lxqt-policykit
    mangohud
    mpv
    neofetch
    papirus-icon-theme
    pavucontrol
    pipewire
    protontricks
    rofi
    slack
    spotify
    usbutils
    vulkan-tools
    vulkan-loader
    vulkan-validation-layers
    wev
    waybar
    wine64
    wireplumber
    wl-clipboard

    inputs.quickshell.packages.${pkgs.system}.default

    #(inputs.nix-gaming.packages.${pkgs.hostPlatform.system}.star-citizen.override {
    #  tricks = [ "arial" "vcrun2019" "win10" "sound=alsa" ];
    #})
  ];
}
