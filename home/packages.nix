{ pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # Fonts
    nerd-fonts.fira-code

    # CLI
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
  ] ++ lib.optionals pkgs.stdenv.isDarwin [
    # MacOS-specific
    cocoapods
    m-cli
  ];
} 