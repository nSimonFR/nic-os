{ pkgs, ... }:
{
  programs.vscode = {
    enable = true;
    mutableExtensionsDir = false;
    # userSettings = {}; # Managed by Github Settings Sync
    extensions = with pkgs.vscode-extensions; [
      viktorqvarfordt.vscode-pitch-black-theme
      vscode-icons-team.vscode-icons

      github.copilot
      eamodio.gitlens
      github.vscode-github-actions

      vscodevim.vim
      esbenp.prettier-vscode

      bbenoist.nix
      hashicorp.terraform
    ];
  };
}