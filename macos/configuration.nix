{ config, pkgs, username, hostname, lib, ... }:
{
  #nix.configureBuildUsers = true;

  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  networking = {
    hostName = hostname;
    localHostName = hostname;
  };

  programs.zsh.enable = true;

  environment.systemPackages = [ pkgs.gcc ];

  security.pam.services.sudo_local.touchIdAuth = true;

  services.skhd = {
    enable = true;
    skhdConfig = builtins.readFile ./dotfiles/skhdrc;
  };

  launchd.daemons."start-programs".serviceConfig = {
    ProgramArguments = [ "open" "/Applications/Vanilla.app/"];
    RunAtLoad = true;
    StandardErrorPath = "/var/log/start-programs.log";
    StandardOutPath = "/var/log/start-programs.log";
  };

  system = import ./components/system.nix { inherit pkgs username; };
  homebrew = import ./components/homebrew.nix { inherit pkgs; };
  services.yabai = import ./components/yabai.nix { inherit pkgs; };
}
