{
  pkgs,
  lib,
  config,
  ...
}:
{
  imports = [
    ../shared/agenix.nix
    ./packages.nix
    ./zsh.nix
    ./claude.nix
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
  xdg.configFile."git/config-personal".source = ./dotfiles/git/gitconfig-personal;
  xdg.configFile."git/ignore".source = ./dotfiles/git/gitignore;
  xdg.configFile."tmux/tmux.conf".source = ./dotfiles/tmux.conf;
  xdg.configFile."atuin/config.toml".source = ./dotfiles/atuin.toml;
  xdg.configFile."mpv/mpv.conf".source = ./dotfiles/mpv.conf;
  xdg.configFile."btop/btop.conf".source = ./dotfiles/btop.conf;
  xdg.configFile."ghostty/config".source = ./dotfiles/ghostty;
  xdg.configFile."zed/settings.json".source = ./dotfiles/editor/zed-settings.json;

  # Cursor: macOS uses ~/Library/Application Support/, Linux uses ~/.config/
  home.file."${
    if pkgs.stdenv.isDarwin then "Library/Application Support" else ".config"
  }/Cursor/User/settings.json".source =
    ./dotfiles/editor/cursor-settings.json;
  home.file."${
    if pkgs.stdenv.isDarwin then "Library/Application Support" else ".config"
  }/Cursor/User/keybindings.json".source =
    ./dotfiles/editor/cursor-keybindings.json;

  home.file.".vimrc".source = ./dotfiles/editor/vim;
  home.file.".var/app/io.github.mactan_sc.RSILauncher/config/starcitizen-lug/launcher.cfg".source =
    ./dotfiles/star-citizen/launcher.cfg;

  # SC-writable files: symlinked directly to the repo via mkOutOfStoreSymlink so
  # SC writes back to the versioned files. Just git commit after SC updates them.
  home.file.".var/app/io.github.mactan_sc.RSILauncher/data/prefix/drive_c/Program Files/Roberts Space Industries/StarCitizen/LIVE/user.cfg".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/star-citizen/user.cfg";

  home.file.".var/app/io.github.mactan_sc.RSILauncher/data/prefix/drive_c/Program Files/Roberts Space Industries/StarCitizen/LIVE/user/client/0/controls/mappings/layout_NICO_exported.xml".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/star-citizen/layout_NICO_exported.xml";
}
