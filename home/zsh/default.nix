{ pkgs, ... }:
{
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
      # Will load the whole folder and source nsimon.plugin.zsh:
      { name = "nsimon"; src = ../dotfiles/zsh; }
    ];

    initExtra = ''
      if [[ $(uname -m) == 'arm64' ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      fi
    '';
  };
}