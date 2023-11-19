{ pkgs, inputs, ... }:
with pkgs; {
  programs.git.enable = true;

  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      vscodevim.vim
    ];
  };

  home.packages = [
    coreutils-full
    curl
    firefox
    gh
    git
    git-lfs
    gnupg
    gnome.nautilus
    gzip
    htop
    jq
    rclone
    ripgrep
    time
    tree
    unzip
    vim
    wget

    _1password
    _1password-gui
    spotify
    slack

    inputs.nix-gaming.packages.${pkgs.system}.star-citizen

    (pkgs.discord.override {
      withOpenASAR = true;
    })
    (pkgs.writeShellScriptBin "discord-fixed" ''
      exec ${pkgs.discord}/bin/discord --enable-features=UseOzonePlatform --ozone-platform=wayland
    '')
  ];
}
