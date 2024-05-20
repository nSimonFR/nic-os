{ config, pkgs, username, hostname, lib, ... }:
{
  services.nix-daemon.enable = true;
  #nix.configureBuildUsers = true;

  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  networking = {
    hostName = hostname;
    localHostName = hostname;
  };

  programs.zsh.enable = true;

  fonts.fontDir.enable = true;

  #environment.systemPackages = [ pkgs.gcc ];

  security.pam.enableSudoTouchIdAuth = true;

  services.activate-system.enable = true;

  services.skhd = {
    enable = true;
    skhdConfig = builtins.readFile ../home/dotfiles/skhdrc;
  };

  launchd.daemons."start-programs".serviceConfig = {
    ProgramArguments = [ "open" "/Applications/Vanilla.app/"];
    RunAtLoad = true;
    StandardErrorPath = "/var/log/start-programs.log";
    StandardOutPath = "/var/log/start-programs.log";
  };

  launchd.daemons."shutdown-work".serviceConfig = {
    ProgramArguments = [ "pkill" "Slack" "Linear" "Cyberduck" "Postman" "Spark Desktop"];
    StartCalendarInterval = [ { Hour = 18; Minute = 00; } ];
    StandardErrorPath = "/var/log/shutdown-work.log";
    StandardOutPath = "/var/log/shutdown-work.log";
  };

  # Silence the 'last login' shell message
  #home-manager.users.${username}.home.file.".hushlogin".text = "";

  system = import ./components/system.nix { inherit pkgs; };
  homebrew = import ./components/homebrew.nix { inherit pkgs; };
  services.yabai = import ./components/yabai.nix { inherit pkgs; };
}
