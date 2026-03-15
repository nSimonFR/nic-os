{
  pkgs,
  lib,
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
  home.file."${if pkgs.stdenv.isDarwin then "Library/Application Support" else ".config"}/Cursor/User/settings.json".source = ./dotfiles/editor/cursor-settings.json;
  home.file."${if pkgs.stdenv.isDarwin then "Library/Application Support" else ".config"}/Cursor/User/keybindings.json".source = ./dotfiles/editor/cursor-keybindings.json;

  home.file.".vimrc".source = ./dotfiles/editor/vim;
}
