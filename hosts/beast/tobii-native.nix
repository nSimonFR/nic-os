# Tobii Eye Tracker 5 — Native Linux support
# Experimental: head pose (pitch/yaw) doesn't work yet, only gaze position.
# The packages live in pkgs/tobii/ (repackaged from the Arch packages at
# https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer).
# VM passthrough config is kept alongside in configuration.nix.
{ pkgs, lib, ... }:

let
  tobii-stream-engine = pkgs.callPackage ../../pkgs/tobii/stream-engine.nix { };
  tobii-engine = pkgs.callPackage ../../pkgs/tobii/engine.nix { };
  tobii-usb-service = pkgs.callPackage ../../pkgs/tobii/usb-service.nix { };
  tobii-pro-eye-tracker-manager = pkgs.callPackage ../../pkgs/tobii/pro-eye-tracker-manager.nix { };
  opentrack-tobii = pkgs.callPackage ../../pkgs/tobii/opentrack-tobii.nix { };

  # Cross-compiled to Windows; `writeText` is passed from the NATIVE package set
  # so the C source file derivation is unchanged by the cross stdenv.
  npclient-shm-dll = pkgs.pkgsCross.mingwW64.callPackage ../../pkgs/tobii/npclient-shm-dll.nix {
    inherit (pkgs) writeText;
  };

  opentrack-sc = pkgs.callPackage ../../pkgs/tobii/opentrack-sc.nix {
    inherit tobii-stream-engine npclient-shm-dll;
  };
in
{
  # Expose /libexec in the system profile so opentrack-sc's NPClient DLLs are reachable
  # at the stable path Z:/run/current-system/sw/libexec/opentrack/ from within the Flatpak.
  environment.pathsToLink = [ "/libexec" ];

  # Make packages available
  environment.systemPackages = [
    tobii-stream-engine
    tobii-pro-eye-tracker-manager
    opentrack-tobii  # AppImage with Tobii tracker — runs opentrack (tracker side)
    opentrack-sc     # Source build — provides NPClient64.dll in /libexec/opentrack/
  ];

  # ── Systemd services ────────────────────────────────────────────────
  systemd.services.tobii-engine = {
    description = "Tobii Engine Service";
    after = [ "network.target" ];
    wantedBy = lib.mkForce [];

    serviceConfig = {
      Type = "simple";
      StateDirectory = "tobii_engine";
      ExecStartPre = pkgs.writeShellScript "tobii-engine-setup" ''
        # Copy engine files to writable state dir so config.db can be written
        src="${tobii-engine}/share/tobii_engine"
        dst="/var/lib/tobii_engine"
        # Only copy if not already populated (preserve calibration data)
        if [ ! -f "$dst/tobii_engine" ]; then
          ${pkgs.coreutils}/bin/cp -r "$src"/* "$dst"/
          ${pkgs.coreutils}/bin/chmod -R u+w "$dst"
        else
          # Always update binary + libs from store (new derivation version)
          ${pkgs.coreutils}/bin/cp -f "$src/tobii_engine" "$dst/"
          ${pkgs.coreutils}/bin/cp -rf "$src/lib" "$dst/"
          ${pkgs.coreutils}/bin/cp -rf "$src/platform_modules" "$dst/"
          ${pkgs.coreutils}/bin/chmod -R u+w "$dst"
        fi
      '';
      ExecStart = "/var/lib/tobii_engine/tobii_engine --daemonize";
      WorkingDirectory = "/var/lib/tobii_engine";
      Restart = "on-abort";
    };
  };

  # ── opentrack-sc user service ────────────────────────────────────────
  # Runs opentrack-sc *inside* the RSILauncher Flatpak sandbox so it inherits
  # WINEPREFIX=/var/data/prefix and PROTONPATH=GE-Proton, sharing SC's wineserver.
  # Not started automatically — manage manually:
  #   systemctl --user start opentrack-sc
  #   systemctl --user stop  opentrack-sc
  systemd.user.services.opentrack-sc = {
    description = "OpenTrack SC — TrackIR head tracking for Star Citizen";
    after = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      # proto-wine needs wine in PATH and the SC WINEPREFIX so its wine wrapper
      # connects to the same wineserver as SC (shared via /tmp socket across Flatpak).
      # FT_SharedMem created by the wrapper is readable by NPClient64.dll via
      # OpenFileMappingA from any wine process on the same wineserver.
      ExecStart = let
        # GE-Proton's `wine` is 32-bit ELF needing /lib/ld-linux.so.2 which is
        # absent in the AppImage bwrap sandbox. Create a `wine` shim that calls
        # `wine64` (64-bit, works on NixOS) so proto-wine finds it in PATH.
        wine-shim = pkgs.writeShellScriptBin "wine" ''
          exec "$HOME/.var/app/io.github.mactan_sc.RSILauncher/.local/share/Steam/compatibilitytools.d/GE-Proton10-30/files/bin/wine64" "$@"
        '';
        wrapper = pkgs.writeShellScript "opentrack-sc-wrapper" ''
          export WINEPREFIX="$HOME/.var/app/io.github.mactan_sc.RSILauncher/data/prefix"
          export PATH="${wine-shim}/bin:$HOME/.var/app/io.github.mactan_sc.RSILauncher/.local/share/Steam/compatibilitytools.d/GE-Proton10-30/files/bin:$PATH"
          exec ${opentrack-tobii}/bin/opentrack-tobii "$@"
        '';
      in "${wrapper}";
      Restart = "on-failure";
      RestartSec = "3s";
    };
  };

  systemd.services.tobii-usb = {
    description = "Tobii USB Service";
    requires = [ "tobii-engine.service" ];
    after = [ "tobii-engine.service" ];
    wantedBy = lib.mkForce [];

    serviceConfig = {
      Type = "forking";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/run/tobiiusb";
      ExecStart = "${tobii-usb-service}/bin/tobiiusbserviced";
      Restart = "on-failure";
    };
  };
}
