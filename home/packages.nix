{
  pkgs,
  masterpkgs,
  lib,
  devSetup ? false,
  ...
}:

{
  home.packages =
    with pkgs;
    [
      # Fonts
      nerd-fonts.fira-code

      # CLI
      atuin
      bash
      btop
      coreutils-full
      curl
      masterpkgs.cursor-cli
      ctop
      direnv
      ed
      fzf
      gh
      git
      git-extras
      git-interactive-rebase-tool
      git-lfs
      # git-spice
      gnupg
      gnused
      gnugrep
      gzip
      jq
      k9s
      kompose
      kubectl
      kubeseal
      less
      nano
      nixfmt-rfc-style
      (lib.lowPrio nodejs_22) # lowPrio to avoid conflict with openclaw
      nodePackages.node-gyp
      nmap
      openssh
      p7zip
      poppler-utils
      # Use lowPrio to avoid conflict with openclaw's bundled python
      (lib.lowPrio (
        python312.withPackages (
          ps: with ps; [
            pandas
            requests
          ]
        )
      ))
      rclone
      redis
      ripgrep
      rsync
      sops
      #thefuck
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
    ]
    ++ lib.optionals devSetup [
      # Dev tools (heavy packages, only on dev machines)
      awscli
      (google-cloud-sdk.withExtraComponents [ google-cloud-sdk.components.gke-gcloud-auth-plugin ])
      gource
      postgresql
      terraform
    ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      # MacOS-specific
      cocoapods
      m-cli
    ];
}
