# LG 38GN950 sphere lighting — the system side of the video-sync ambient
# daemon. The package (protocol bindings, HID codec, screencopy client) lives
# in pkgs/rgb/lg-sphere-ambient.
{
  lib,
  pkgs,
  ...
}:

let
  lg-sphere-ambient = pkgs.callPackage ../../pkgs/rgb/lg-sphere-ambient { };
in
{
  # Give the logged-in user access to /dev/hidraw11 (the sphere-lighting
  # endpoint on the LG 38GN950) via group ownership. We previously used
  # systemd-logind's TAG+="uaccess", but the resulting ACL came up with
  # mask::--- on at least one reboot — the user entry was user:nsimon:rw-
  # but the mask collapsed effective rights to nothing, the daemon
  # crash-looped on "unable to open device", and a manual
  # `setfacl -m m::rw` was needed to recover. GROUP="input" MODE="0660"
  # skips the ACL/logind path entirely and is invariant across reboots.
  services.udev.extraRules = ''
    # LG 38GN950 (UltraGear) sphere lighting HID interface
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="043e", ATTRS{idProduct}=="9a8a", GROUP="input", MODE="0660"
  '';

  environment.systemPackages = [ lg-sphere-ambient ];

  # OpenRGB's LG plugin opens /dev/hidraw11 too — hidraw allows concurrent
  # writers, so its writes race ours and the sphere flashes on every
  # disagreement. Disable OpenRGB's LG-monitor detector before the server
  # starts so this daemon is the sole writer; the rest of the OpenRGB
  # device list (RAM, mobo, mouse, gamepad) is unaffected.
  systemd.services.openrgb.preStart = lib.mkAfter ''
    cfg=/var/lib/OpenRGB/OpenRGB.json
    if [ -s "$cfg" ]; then
      ${pkgs.jq}/bin/jq '.Detectors.detectors."LG 27GN950-B Monitor" = false' "$cfg" > "$cfg.tmp" \
        && mv "$cfg.tmp" "$cfg"
    else
      mkdir -p /var/lib/OpenRGB
      printf '{"Detectors":{"detectors":{"LG 27GN950-B Monitor":false}}}' > "$cfg"
    fi
  '';

  # OpenRGB's NVIDIA FE GPU detector dlopens libnvidia-api.so.1, but on
  # NixOS that lib sits in /run/opengl-driver/lib/ — not in the default
  # ld.so search path — so the dlopen silently fails and the GeForce
  # side-logo never gets enumerated. With this env var set,
  # NvAPI_Initialize() returns 0 and NvAPI_EnumPhysicalGPUs() reports 1
  # GPU on a 3080 Ti FE; the "Nvidia NvAPI Illumination" detector then
  # produces an "NVIDIA GeForce RTX 3080 Ti FE" device on the SDK.
  systemd.services.openrgb.environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";

  # User service — starts at login, restarts on failure, ends gracefully on logout.
  systemd.user.services.lg-sphere-ambient = {
    description = "LG 38GN950 sphere-lighting ambient sync";
    after = [ "graphical-session.target" ];
    wants = [ "graphical-session.target" ];
    wantedBy = [ "default.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = ''${lg-sphere-ambient}/bin/lg-sphere-ambient \
        --output DP-1 --fps 30 --brightness 12 \
        --openrgb --openrgb-devices all \
        --openrgb-zone-sizes "motherboard/Aura Addressable 1=24,motherboard/Aura Addressable 2=0,motherboard/Aura Addressable 3=8"'';
      Restart = "on-failure";
      RestartSec = "5s";
      # turn the lights off if the service is stopped or fails terminally
      TimeoutStopSec = "5s";
      KillSignal = "SIGTERM";
    };
  };
}
