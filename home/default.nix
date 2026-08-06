{
  pkgs,
  lib,
  config,
  host,
  ...
}:
{
  imports = [
    ../shared/agenix.nix
    ./packages.nix
    ./zsh.nix
    ./atuin.nix
    ./claude.nix
    ./claude-mtg.nix
    ./claude-aperture-shim.nix
    ./mcp.nix
    ./ssh.nix
    ./wakatime.nix
    ./editors.nix
    ./pi-coding-agent
    ./rtk
  ];

  fonts.fontconfig.enable = true;

  home.stateVersion = "25.11";
  programs.home-manager.enable = true;

  # Ensure home-manager packages are in PATH (needed when integrated with nix-darwin)
  home.sessionPath = [
    "$HOME/.local/state/nix/profiles/home-manager/home-path/bin"
  ];

  xdg.enable = true;
  xdg.configFile."git/config".source = ./dotfiles/git/gitconfig;
  xdg.configFile."git/config-shared".source = ./dotfiles/git/gitconfig-shared;
  xdg.configFile."git/ignore".source = ./dotfiles/git/gitignore;
  xdg.configFile."jj/config.toml".source = ./dotfiles/jj/config.toml;
  xdg.configFile."tmux/tmux.conf".source = ./dotfiles/tmux.conf;
  xdg.configFile."atuin/config.toml".source = ./dotfiles/atuin.toml;
  xdg.configFile."mpv/mpv.conf".source = ./dotfiles/mpv.conf;
  xdg.configFile."btop/btop.conf".source = ./dotfiles/btop.conf;
  xdg.configFile."ghostty/config".source = ./dotfiles/ghostty;

  # Editors (VS Code, Cursor, Zed, Vim) live in ./editors.nix.

  # Star Citizen (Flatpak RSI launcher) — BeAsT only. This module is imported by
  # every host, so without the gate the headless Pi and the Mac both got a
  # launcher config plus two symlinks into a Wine prefix that does not exist
  # there (the two mkOutOfStoreSymlinks are dangling on those hosts by
  # construction — nothing ever creates the prefix).
  home.file = lib.optionalAttrs host.runsStarCitizen {
    ".var/app/io.github.mactan_sc.RSILauncher/config/starcitizen-lug/launcher.cfg".source =
      ./dotfiles/star-citizen/launcher.cfg;

    # SC-writable files: symlinked directly to the repo via mkOutOfStoreSymlink so
    # SC writes back to the versioned files. Just git commit after SC updates them.
    ".var/app/io.github.mactan_sc.RSILauncher/data/prefix/drive_c/Program Files/Roberts Space Industries/StarCitizen/LIVE/user.cfg".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/star-citizen/user.cfg";

    ".var/app/io.github.mactan_sc.RSILauncher/data/prefix/drive_c/Program Files/Roberts Space Industries/StarCitizen/LIVE/user/client/0/controls/mappings/layout_NICO_exported.xml".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/star-citizen/layout_NICO_exported.xml";
  };
}
