{ pkgs, lib, ... }:

let
  # ============================================
  # CONFIGURE HERE
  # ============================================
  device = "bellowing-paca";  # ratbagctl device name

  defaultProfile = 1;

  # Window class pattern -> profile number
  profiles = {
    "starcitizen" = 2;
  };
  # ============================================

  # Generate bash case patterns from the profiles attrset
  profilePatterns = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (pattern: profile: ''
      *"${pattern}"*) ${pkgs.libratbag}/bin/ratbagctl "${device}" profile active set ${toString profile} ;;'')
    profiles
  );

  # Generate grep patterns for checking if any game is running
  checkPatterns = lib.concatStringsSep " -e " (lib.attrNames profiles);

  script = pkgs.writeShellScript "piper-autoprofile" ''
    switch_if_needed() {
      ${pkgs.hyprland}/bin/hyprctl clients -j | ${pkgs.gnugrep}/bin/grep -qi -e ${checkPatterns} && return
      ${pkgs.libratbag}/bin/ratbagctl "${device}" profile active set ${toString defaultProfile}
    }

    ${pkgs.socat}/bin/socat -U - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock | while read -r line; do
      case $line in
        openwindow*)
          case $line in
            ${profilePatterns}
          esac
          ;;
        closewindow*)
          switch_if_needed
          ;;
      esac
    done
  '';

in
{
  systemd.user.services.piper-autoprofile = {
    description = "Auto-switch Piper mouse profiles for games";
    wantedBy = [ "hyprland-session.target" ];
    after = [ "hyprland-session.target" ];
    serviceConfig = {
      ExecStart = script;
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
