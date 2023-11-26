{ pkgs, ... }:
{
  imports = [
    ./firefox
    ./vscode
    ./zsh
  ];

  nixpkgs.config = {
    allowUnfree = true;
    allowUnfreePredicate = _: true;
  };

  programs.home-manager.enable = true;
  home.stateVersion = "23.05";
  xdg.enable = true;

  home.packages = with pkgs; [
    awscli
    bash
    btop
    coreutils-full
    curl
    ctop
    direnv
    docker
    ed
    gh
    git
    git-interactive-rebase-tool
    git-extras
    git-lfs
    gnupg
    gource
    gzip
    terraform
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
      # withVencord = true;
    })
    (pkgs.writeShellScriptBin "discord-fixed" ''
      exec ${pkgs.discord}/bin/discord --enable-features=UseOzonePlatform --ozone-platform=wayland
    '')
  ];

  xdg.configFile."git/config".source = ./dotfiles/gitconfig;
  xdg.configFile."git/ignore".source = ./dotfiles/gitignore;
  xdg.configFile."tmux/tmux.conf".source = ./dotfiles/tmux.conf;
  home.file.".vimrc".source = ./dotfiles/vim;
}
