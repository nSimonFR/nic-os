{ pkgs, ... }:
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autocd = true;
    autosuggestion.enable = true;

    history = {
      ignoreDups = true;
      save = 1000000;
      size = 1000000;
    };
      
    zplug = {
      enable = true;
      plugins = [
        { name = "zsh-users/zsh-syntax-highlighting"; }
        { name = "spaceship-prompt/spaceship-prompt"; }
      ];
    };

    plugins = [
      # Will load the whole folder and source nsimon.plugin.zsh:
      { name = "nsimon"; src = ./dotfiles/zsh; }
    ];
  };
}
