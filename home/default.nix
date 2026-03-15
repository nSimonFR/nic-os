{
  pkgs,
  lib,
  stdenv,
  ...
}:
{
  imports = [
    ./packages.nix
    ./zsh.nix
  ];

  fonts.fontconfig.enable = true;

  home.stateVersion = "25.11";
  programs.home-manager.enable = true;

  # Ensure home-manager packages are in PATH (needed when integrated with nix-darwin)
  home.sessionPath = [
    "$HOME/.local/state/nix/profiles/home-manager/home-path/bin"
  ];

  xdg.enable = true;
  xdg.configFile."git/config".source = ./dotfiles/gitconfig;
  xdg.configFile."git/config-shared".source = ./dotfiles/gitconfig-shared;
  xdg.configFile."git/config-personal".source = ./dotfiles/gitconfig-personal;
  xdg.configFile."git/ignore".source = ./dotfiles/gitignore;
  xdg.configFile."tmux/tmux.conf".source = ./dotfiles/tmux.conf;
  xdg.configFile."atuin/config.toml".source = ./dotfiles/atuin.toml;
  xdg.configFile."mpv/mpv.conf".source = ./dotfiles/mpv.conf;
  xdg.configFile."ghostty/config".source = ./dotfiles/ghostty;
  xdg.configFile."zed/settings.json".source = ./dotfiles/zed-settings.json;

  # Cursor: macOS uses ~/Library/Application Support/, Linux uses ~/.config/
  home.file."${if stdenv.isDarwin then "Library/Application Support" else ".config"}/Cursor/User/settings.json".source = ./dotfiles/cursor-settings.json;
  home.file."${if stdenv.isDarwin then "Library/Application Support" else ".config"}/Cursor/User/keybindings.json".source = ./dotfiles/cursor-keybindings.json;

  home.file.".vimrc".source = ./dotfiles/vim;
}
