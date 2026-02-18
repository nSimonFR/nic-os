{
  config,
  pkgs,
  inputs,
  unstablepkgs,
  masterpkgs,
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
    beeper
    cliphist
    libnotify
    masterpkgs.code-cursor
    dconf
    docker
    dualsensectl
    dunst
    kitty
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

    # Star Citizen RSI Launcher
    # FIXME: nix-citizen's wine-astral passes `wineRelease` to nixpkgs base.nix,
    # which no longer accepts it on release-25.11. Uncomment when nix-citizen is updated.
    # (inputs.nix-citizen.packages.${pkgs.stdenv.hostPlatform.system}.rsi-launcher-unwrapped.override {
    #   # umu.enable = true;
    #   location = "/mnt/games-linux/star-citizen";
    # })
  ];
}
