{
  pkgs,
  unstablePkgs,
  inputs,
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
      age
      unstablePkgs.atuin
      bash
      btop
      coreutils-full
      curl
      codex
      unstablePkgs.cursor-cli
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
      unstablePkgs.jujutsu
      jq
      k9s
      kompose
      kubectl
      kubeseal
      less
      nano
      nixfmt-rfc-style
      # lowPrio so a package that vendors its own node (claude-code, hermes, …)
      # wins the profile collision instead of erroring. Originally added for
      # OpenClaw (retired — ADR 0001); kept because the hazard outlived it.
      (lib.lowPrio nodejs_22)
      nodePackages.node-gyp
      nmap
      openssh
      p7zip
      poppler-utils
      # Same rationale as nodejs_22 above: lowPrio yields to any package that
      # ships its own python interpreter.
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
