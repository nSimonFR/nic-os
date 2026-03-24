{ pkgs, lib, ... }:

let
  # ============================================
  # CONFIGURE HERE
  # ============================================
  deviceProduct = "G502";  # grep pattern matched against ratbagctl list output

  defaultProfile = 1;

  # Window class pattern -> profile number
  profiles = {
    "starcitizen" = 2;
  };
  # ============================================

  # Generate bash case patterns from the profiles attrset
  profilePatterns = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (pattern: profile: ''
      *"${pattern}"*) ratbag_set_profile ${toString profile} ;;'')
    profiles
  );

  # Generate grep patterns for checking if any game is running
  checkPatterns = lib.concatStringsSep " -e " (lib.attrNames profiles);

  script = pkgs.writeShellScript "piper-autoprofile" ''
    get_device() {
      ${pkgs.libratbag}/bin/ratbagctl list 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -i "${deviceProduct}" \
        | ${pkgs.coreutils}/bin/cut -d: -f1 \
        | head -1
    }

    ratbag_set_profile() {
      local dev
      dev=$(get_device)
      [ -n "$dev" ] && ${pkgs.libratbag}/bin/ratbagctl "$dev" profile active set "$1"
    }

    switch_if_needed() {
      ${pkgs.hyprland}/bin/hyprctl clients -j | ${pkgs.gnugrep}/bin/grep -qi -e ${checkPatterns} && return
      ratbag_set_profile ${toString defaultProfile}
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
