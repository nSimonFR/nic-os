{
  pkgs,
  unstablepkgs,
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

  xdg.enable = true;
  xdg.configFile."git/config".source = ./dotfiles/gitconfig;
  xdg.configFile."git/ignore".source = ./dotfiles/gitignore;
  xdg.configFile."tmux/tmux.conf".source = ./dotfiles/tmux.conf;
  xdg.configFile."atuin/config.toml".source = ./dotfiles/atuin.toml;
  xdg.configFile."mpv/mpv.conf".source = ./dotfiles/mpv.conf;
  home.file.".vimrc".source = ./dotfiles/vim;
}
