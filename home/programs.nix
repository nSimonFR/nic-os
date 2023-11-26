{ pkgs, inputs, ... }:
with pkgs; {
  xdg.enable = true;
  programs.home-manager.enable = true;

  home.packages = [
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

  programs.zsh = {
    enable = true;
    enableAutosuggestions = true;
    enableCompletion = true;
    autocd = true;

    history = {
      ignoreDups = true;
      save = 1000000;
      size = 1000000;
    };
      
    zplug = {
      enable = true;
      plugins = [
        { name = "zsh-users/zsh-syntax-highlighting"; }
        { name = "zsh-users/zsh-history-substring-search"; }
        { name = "agkozak/zsh-z"; }
        { name = "spaceship-prompt/spaceship-prompt"; }
      ];
    };

    plugins = [
      { name = "nsimon"; src = ./dotfiles/zsh; }
    ];
  };

  xdg.configFile."git/config".source = ./dotfiles/gitconfig;
  xdg.configFile."git/ignore".source = ./dotfiles/gitignore;
  xdg.configFile."tmux/tmux.conf".source = ./dotfiles/tmux.conf;
  home.file.".vimrc".source = ./dotfiles/vim;
}
