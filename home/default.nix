{ pkgs, unstablepkgs, lib, stdenv, ... }:
{
  imports = [
    ./packages.nix
    ./firefox
    ./zsh
    #./vscode
  ];

  nixpkgs.config.allowUnfree = true;

  home.stateVersion = "25.05";
  programs.home-manager.enable = true;
  fonts.fontconfig.enable = true;
  xdg.enable = true;

  xdg.configFile."git/config".source = ./dotfiles/gitconfig;
  xdg.configFile."git/ignore".source = ./dotfiles/gitignore;
  xdg.configFile."tmux/tmux.conf".source = ./dotfiles/tmux.conf;
  xdg.configFile."atuin/config.toml".source = ./dotfiles/atuin.toml;
  xdg.configFile."mpv/mpv.conf".source = ./dotfiles/mpv.conf;
  home.file.".vimrc".source = ./dotfiles/vim;
}
