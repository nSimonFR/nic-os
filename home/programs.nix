{ pkgs, inputs, ... }:
with pkgs; {
  xdg.enable = true;
  programs.home-manager.enable = true;

  home.packages = [
    awscli
    bash
    coreutils-full
    curl
    ctop
    direnv
    docker
    ed
    gh
    git
    git-extras
    git-lfs
    gnupg
    gource
    gzip
    terraform
    htop
    jq
    k9s
    kubeseal
    less
    nano
    nmap
    openssh
    rclone
    ripgrep
    rsync
    sops
    time
    tmux
    tree
    unzip
    vim
    watchman
    wget
    youtube-dl
    yq
    zsh

    _1password
    _1password-gui
    spotify
    slack

    #inputs.nix-gaming.packages.${pkgs.system}.star-citizen

    (pkgs.discord.override {
      withOpenASAR = true;
    })
    (pkgs.writeShellScriptBin "discord-fixed" ''
      exec ${pkgs.discord}/bin/discord --enable-features=UseOzonePlatform --ozone-platform=wayland
    '')
  ];

  xdg.configFile."git/config".source = ./dotfiles/gitconfig;
  xdg.configFile."git/ignore".source = ./dotfiles/gitignore;
  xdg.configFile."tmux/tmux.conf".source = ./dotfiles/tmux.conf;
}
