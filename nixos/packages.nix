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

    # LUG Helper for Star Citizen on Linux
    cabextract
    unzip
    winetricks

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

    (inputs.nix-citizen.packages.${pkgs.system}.star-citizen-git.override {
      # disableEac = false;
      # preCommands = ''
      #   export DXVK_HUD=compiler;
      #   export MANGO_HUD=1;
      # '';
      # helperScript.enable = true;
      # patchXwayland = true;
      # umu.enable = true;
      location = "/mnt/games-linux/star-citizen";
    })

    # (inputs.star-citizen-nix-gaming.packages.${pkgs.system}.star-citizen.override {
    #   wineDllOverrides = [ ];
    #   useUmu = true;
    #   gameScopeEnable = true;
    #   gamescope = pkgs.gamescope.overrideAttrs (_: {
    #     NIX_CFLAGS_COMPILE = [ "-fno-fast-math" ];
    #   });
    #   gameScopeArgs = [
    #     "--backend"
    #     "sdl"
    #     # "--fullscreen"
    #     "--force-grab-cursor"
    #     # "--expose-wayland"
    #     "--force-windows-fullscreen"
    #   ];
    # })
  ];
}
