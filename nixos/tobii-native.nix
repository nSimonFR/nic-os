# Tobii Eye Tracker 5 — Native Linux support
# Experimental: head pose (pitch/yaw) doesn't work yet, only gaze position.
# Repackaged from Arch packages at https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer
# VM passthrough config is kept alongside in configuration.nix.
{ pkgs, lib, ... }:

let
  # ── tobii-stream-engine ──────────────────────────────────────────────
  # Shared library + headers for the Tobii Stream Engine API
  tobii-stream-engine = pkgs.stdenv.mkDerivation {
    pname = "tobii-stream-engine";
    version = "4.24.0";

    src = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/megagtrwrath/tobii_eye_tracker_linux_installer/master/tobii-stream-engine-4.24.0-linux-x86_64.tar.gz";
      hash = "sha256-dItQCNLAkau14zL/dvpifynWrNc8HIVRM0O4+oFY6zA=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.avahi # libavahi-client, libavahi-common
    ];

    sourceRoot = "tobii-stream-engine-4.24.0";

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/include/tobii
      cp lib/libtobii_stream_engine.so $out/lib/
      cp include/tobii/*.h $out/include/tobii/
      runHook postInstall
    '';
  };

  # ── tobii-engine ─────────────────────────────────────────────────────
  # Main Tobii Engine daemon (face tracking, calibration, firmware)
  tobii-engine = pkgs.stdenv.mkDerivation {
    pname = "tobii-engine";
    version = "0.1.6.193rc";

    src = pkgs.fetchurl {
      url = "https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer/releases/download/v1/tobii_engine_linux-0.1.6.193rc-1-x86_64.pkg.tar.zst";
      hash = "sha256-duCqFXZk7grNIsRK/4vu4EAkCZAmkYtcUrk8pKh9QcE=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.zstd ];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib # libstdc++
      pkgs.zlib             # libz
      pkgs.sqlcipher        # libsqlcipher
      pkgs.libgcc           # libgomp (via libseeta)
    ];

    unpackPhase = ''
      tar xf $src
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/share
      cp -r usr/share/tobii_engine $out/share/tobii_engine

      # Add bundled libs to rpath so self-referential deps resolve
      addAutoPatchelfSearchPath $out/share/tobii_engine/lib
      addAutoPatchelfSearchPath $out/share/tobii_engine/platform_modules
      runHook postInstall
    '';
  };

  # ── tobii-usb-service ────────────────────────────────────────────────
  # USB communication daemon for Tobii hardware
  tobii-usb-service = pkgs.stdenv.mkDerivation {
    pname = "tobii-usb-service";
    version = "2.1.5";

    src = pkgs.fetchurl {
      url = "https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer/releases/download/v1/tobiiusbservice-2.1.5-1-x86_64.pkg.tar.zst";
      hash = "sha256-+QLdjfJ7oLCAU66R49KHHU/drhXRUlBYRmjLpCYlmnk=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.zstd ];
    buildInputs = [
      pkgs.systemd # libudev
    ];

    unpackPhase = ''
      tar xf $src
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/lib
      cp usr/bin/tobiiusbserviced $out/bin/
      cp usr/local/lib/tobiiusb/*.so $out/lib/

      # Bundled libs reference each other
      addAutoPatchelfSearchPath $out/lib
      runHook postInstall
    '';
  };

  # ── tobii-pro-eye-tracker-manager ────────────────────────────────────
  # Electron calibration/configuration app
  tobii-pro-eye-tracker-manager = pkgs.stdenv.mkDerivation {
    pname = "tobii-pro-eye-tracker-manager";
    version = "2.6.1";

    src = pkgs.fetchurl {
      url = "https://github.com/megagtrwrath/tobii_eye_tracker_linux_installer/releases/download/v1/tobiiproeyetrackermanager-2.6.1-1-x86_64.pkg.tar.zst";
      hash = "sha256-IiDsq1GFKEQQCmwev9I0sJgRvqgJm5M1oNvG1dIU7ys=";
    };

    nativeBuildInputs = [
      pkgs.autoPatchelfHook
      pkgs.makeWrapper
      pkgs.zstd
    ];

    buildInputs = with pkgs; [
      alsa-lib
      at-spi2-atk
      cairo
      cups
      dbus
      expat
      gdk-pixbuf
      glib
      gtk3
      libdrm
      libxkbcommon
      mesa
      nspr
      nss
      pango
      systemd        # libudev
      xorg.libX11
      xorg.libXcomposite
      xorg.libXdamage
      xorg.libXext
      xorg.libXfixes
      xorg.libXrandr
      xorg.libxcb
    ];

    runtimeDependencies = [
      pkgs.systemd   # libudev at runtime
    ];

    unpackPhase = ''
      tar xf $src
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/opt $out/bin $out/share

      cp -r opt/TobiiProEyeTrackerManager $out/opt/TobiiProEyeTrackerManager

      # Desktop file and icon
      if [ -d usr/share/applications ]; then
        cp -r usr/share/applications $out/share/
      fi
      if [ -d usr/share/icons ]; then
        cp -r usr/share/icons $out/share/
      fi

      # Wrapper with --no-sandbox (required for Electron without suid chrome-sandbox)
      makeWrapper $out/opt/TobiiProEyeTrackerManager/tobiiproeyetrackermanager $out/bin/tobii-pro-eye-tracker-manager \
        --add-flags "--no-sandbox"

      runHook postInstall
    '';
  };

  # ── opentrack-tobii ──────────────────────────────────────────────────
  # OpenTrack AppImage build with Tobii input plugin
  opentrack-tobii = pkgs.appimageTools.wrapType2 {
    pname = "opentrack-tobii";
    version = "2026.1.0";

    src = pkgs.fetchurl {
      url = "https://github.com/megagtrwrath/opentrack-appimage-ci/releases/download/opentrack-2026.1.0-20260312-072213Z/OpenTrack-TOBII-2026.1.0-x86_64.AppImage";
      hash = "sha256-1h/W3NMMrNiBHD3dlebIdjfFf3tALsCexIAlB6E7mK8=";
    };
  };

in
{
  # Make packages available
  environment.systemPackages = [
    tobii-stream-engine
    tobii-pro-eye-tracker-manager
    opentrack-tobii
  ];

  # ── Systemd services ────────────────────────────────────────────────
  systemd.services.tobii-engine = {
    description = "Tobii Engine Service";
    after = [ "network.target" ];
    wantedBy = [ "graphical.target" ];

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

  systemd.services.tobii-usb = {
    description = "Tobii USB Service";
    requires = [ "tobii-engine.service" ];
    after = [ "tobii-engine.service" ];
    wantedBy = [ "graphical.target" ];

    serviceConfig = {
      Type = "forking";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/run/tobiiusb";
      ExecStart = "${tobii-usb-service}/bin/tobiiusbserviced";
      Restart = "on-failure";
    };
  };
}
