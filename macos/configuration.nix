{ config, pkgs, username, hostname, ... }:
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

  # Silence the 'last login' shell message
  #home-manager.users.${username}.home.file.".hushlogin".text = "";

  services.activate-system.enable = true;

  services.skhd = {
    enable = true;
    skhdConfig = builtins.readFile ../home/dotfiles/skhdrc;
  };

  system = import ./components/system.nix { inherit pkgs; };
  homebrew = import ./components/homebrew.nix { inherit pkgs; };
  services.yabai = import ./components/yabai.nix { inherit pkgs; };
  services.spacebar = import ./components/spacebar.nix { inherit pkgs; };

  launchd.user.agents.spacebar.serviceConfig.StandardErrorPath = "/tmp/spacebar.err.log";
  launchd.user.agents.spacebar.serviceConfig.StandardOutPath = "/tmp/spacebar.out.log";
}
