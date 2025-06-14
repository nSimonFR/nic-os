{ pkgs, unstablepkgs,... }:
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

  home.stateVersion = "25.05";
  programs.home-manager.enable = true;
  fonts.fontconfig.enable = true;
  xdg.enable = true;

  home.packages = with pkgs; [
    fira-code
    fira-code-symbols
    font-awesome
  ] ++ [
    atuin
    awscli
    bash
    btop
    coreutils-full
    curl
    ctop
    direnv
    ed
    fzf
    (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
    gh
    git
    git-extras
    git-interactive-rebase-tool
    git-lfs
    git-spice
    gnupg
    gnused
    gnugrep
    gource
    gzip
    terraform
    jq
    k9s
    kompose
    kubectl
    kubeseal
    less
    nano
    nodejs_20
    nodePackages.node-gyp
    nmap
    openssh
    poppler_utils
    postgresql
    python3
    rclone
    redis
    ripgrep
    rsync
    sops
    thefuck
    time
    tmux
    tree
    unzip
    vim
    watchman
    wget
    yarn
    yq
    zoxide
    zsh
  ] ++ lib.optionals stdenv.isDarwin [
    cocoapods
    m-cli # useful macOS CLI commands
  ] ++ lib.optionals (!stdenv.isDarwin) [
    _1password-gui
    docker
    slack
    spotify
    #inputs.nix-gaming.packages.${pkgs.system}.star-citizen
    (discord.override {
      withOpenASAR = true;
      # withVencord = true;
    })
    (writeShellScriptBin "discord-fixed" ''
      exec ${discord}/bin/discord --enable-features=UseOzonePlatform --ozone-platform=wayland
    '')
  ];

  xdg.configFile."git/config".source = ./dotfiles/gitconfig;
  xdg.configFile."git/ignore".source = ./dotfiles/gitignore;
  xdg.configFile."tmux/tmux.conf".source = ./dotfiles/tmux.conf;
  xdg.configFile."atuin/config.toml".source = ./dotfiles/atuin.toml;
  xdg.configFile."mpv/mpv.conf".source = ./dotfiles/mpv.conf;
  home.file.".vimrc".source = ./dotfiles/vim;
}
