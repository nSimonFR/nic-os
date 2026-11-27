# Home Manager for the stock-SteamOS Deck (user deck). Standalone, not ./home:
# that pulls in agenix secrets the Deck can't decrypt and the agent tooling.
#   home-manager switch --flake github:nSimonFR/nic-os#deck@steamdeck
{ pkgs, ... }:
{
  home = {
    username = "deck";
    homeDirectory = "/home/deck";
    stateVersion = "26.05";
    packages = with pkgs; [
      btop
      fd
      git
      htop
      jq
      mosh
      ncdu
      ripgrep
      rsync
      tmux
      tree
    ];
  };
  programs.home-manager.enable = true;
}
