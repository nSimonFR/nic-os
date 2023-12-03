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

  home.stateVersion = "23.05";
  programs.home-manager.enable = true;
  fonts.fontconfig.enable = true;
  xdg.enable = true;

  home.packages = with pkgs; [
    fira-code
    fira-code-symbols
    font-awesome
  ] ++ [
    awscli
    bash
    btop
    coreutils-full
    curl
    ctop
    direnv
    docker
    ed
    google-cloud-sdk
    gh
    git
    git-interactive-rebase-tool
    git-extras
    git-lfs
    gnupg
    gnused
    gnugrep
    gource
    gzip
    terraform
    jq
    k9s
    kompose
    krew
    kubectl
    kubeseal
    less
    nano
    nodejs
    nodePackages.npm
    nodePackages.node-gyp
    nmap
    openssh
    pinentry
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
    yarn
    youtube-dl
    yq
    zsh
  ] ++ lib.optionals stdenv.isDarwin [
    cocoapods
    m-cli # useful macOS CLI commands
  ] ++ lib.optionals (!stdenv.isDarwin) [
    _1password-gui
    slack
    spotify
    #inputs.nix-gaming.packages.${pkgs.system}.star-citizen
    (pkgs.discord.override {
      withOpenASAR = true;
      # withVencord = true;
    })
    (pkgs.writeShellScriptBin "discord-fixed" ''
      exec ${pkgs.discord}/bin/discord --enable-features=UseOzonePlatform --ozone-platform=wayland
    '')
  ];

  # TODO
  # - Unclutter
  # - Contexts.App
  # - AirBuddy

  xdg.configFile."git/config".source = ./dotfiles/gitconfig;
  xdg.configFile."git/ignore".source = ./dotfiles/gitignore;
  xdg.configFile."tmux/tmux.conf".source = ./dotfiles/tmux.conf;
  home.file.".vimrc".source = ./dotfiles/vim;
}
