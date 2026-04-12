{
  config,
  pkgs,
  inputs,
  unstablePkgs,
  ...
}:
let
  # TODO
  waylandOverride =
    pkg: attrs:
    pkg.overrideAttrs (
      old:
      attrs
      // {
        configureFlags = (old.configureFlags or [ ]) ++ [
          "--enable-wayland-ime"
          "--enable-features=UseOzonePlatform"
          "--ozone-platform=wayland"
        ];
        doCheck = false;
      }
    );
in
{
  home.packages = with pkgs; [
    _1password-gui
    bitwarden-desktop
    rbw
    pinentry-gnome3
    pinentry-rofi
    rofi-rbw-wayland
    beeper
    bemoji
    cliphist
    libnotify
    unstablePkgs.code-cursor
    dconf
    docker
    dualsensectl
    dunst
    ghostty
    goverlay
    hypridle
    hyprlock
    hyprpaper
    hyprshot
    hyprsunset
    kubernetes-helm
    lxqt.lxqt-policykit
    mangohud
    mpv
    qbittorrent
    neofetch
    papirus-icon-theme
    pavucontrol
    pipewire
    prismlauncher
    rofi
    slack
    (waylandOverride spotify { withWayland = true; })
    wev
    waybar
    wireplumber
    wl-clipboard
    xorg.xeyes

    # ISO mounting / reading
    fuseiso
    cdrtools
    p7zip

    # vesktop
    # webcord
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
    
    inputs.nix-citizen.packages.${pkgs.stdenv.hostPlatform.system}.rsi-launcher
  ];

}
