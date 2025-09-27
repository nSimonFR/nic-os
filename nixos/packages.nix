{ config, pkgs, inputs, unstablepkgs, ... }: {
  home.packages = with pkgs; [
    _1password-gui
    alacritty
    beeper
    cliphist
    code-cursor
    dconf
    docker
    dualsensectl
    dunst
    goverlay
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
    rofi
    slack
    spotify
    wev
    waybar
    wireplumber
    wl-clipboard

    (discord.override {
      withOpenASAR = true;
      withVencord = true;
    })

    (pkgs.lutris.override {
      extraPkgs = pkgs: [
        pkgs.wineWowPackages.waylandFull
        pkgs.winetricks
        pkgs.proton-ge-bin
        pkgs.gamescope
        pkgs.gamemode
      ];
    })
  ];
}
