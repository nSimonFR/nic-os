{ config, pkgs, lib, ... }:
# AltServer-Linux on rpi5 for iOS app refresh. Architecture:
#
#   netmuxd (prebuilt) — discovers the iPhone via mDNS (_apple-mobdev2._tcp)
#     on the LAN and bridges its lockdownd protocol over a local unix socket
#     where AltServer expects usbmuxd to be.
#   AltServer (prebuilt, daemon mode) — listens for AltStore refresh requests
#     from the iPhone (auto-discovered via _altserver._tcp on the LAN).
#     Anisette token endpoint via $ALTSERVER_ANISETTE_SERVER.
#
# Apple ID is NOT configured here: AltStore on the iPhone stores it locally
# and sends it with each refresh request, so the server runs without creds.
#
# The pairing trust record is staged from agenix into /var/lib/lockdown/<UDID>.plist
# at activation time. The plist content is the user's macOS lockdownd record
# (libimobiledevice's on-disk format matches macOS's by design).
let
  altserverPkg = pkgs.callPackage ./altserver/altserver-linux.nix { };
  netmuxdPkg   = pkgs.callPackage ./altserver/netmuxd.nix { };

  # AltServer's mDNS publishing path: it shells out to a python3 helper that
  # CDLLs `libdns_sd.so`. The default nixpkgs avahi build omits the libdns_sd
  # compat shim, and python3 isn't on the systemd PATH — both must be wired
  # in explicitly or AltStore on the iPhone can't auto-discover the server.
  avahiCompat = pkgs.avahi.override { withLibdnssdCompat = true; };

  # 40-char hex from /var/db/lockdown/<UDID>.plist on the Mac. Set this before
  # the first rebuild that actually intends to talk to the iPhone — the activation
  # script no-ops cleanly while it's still REPLACE_ME (the agenix file may also
  # be absent until you've encrypted it).
  iPhoneUdid = "00008030-0004452601FA802E";
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/lockdown 0700 root root -"
  ];

  # Stage the pairing record into libimobiledevice's expected location. Skips
  # cleanly if either the agenix secret or the UDID placeholder is missing,
  # so the module can land before the secret is encrypted.
  system.activationScripts.altserverPairing = lib.stringAfter [ "agenix" ] ''
    if [ "${iPhoneUdid}" != "REPLACE_ME" ] && [ -r /run/agenix/altserver-pairing-plist ]; then
      install -d -m 700 /var/lib/lockdown
      install -m 600 -o root -g root \
        /run/agenix/altserver-pairing-plist \
        /var/lib/lockdown/${iPhoneUdid}.plist
    fi
  '';

  # mDNS for two directions: resolving the iPhone's _apple-mobdev2._tcp.local
  # advertisement (consumer) AND publishing AltServer's own _altserver._tcp
  # so AltStore on the iPhone can auto-discover us (producer).
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      userServices = true;
    };
  };

  systemd.services.netmuxd = {
    description = "netmuxd — network multiplexer for iOS";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "avahi-daemon.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${netmuxdPkg}/bin/netmuxd";
      Restart = "on-failure";
      RestartSec = "10s";
      MemoryMax = "128M";
    };
  };

  systemd.services.altserver = {
    description = "AltServer-Linux — iOS app refresh daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "netmuxd.service" "avahi-daemon.service" "network-online.target" ];
    requires = [ "netmuxd.service" "avahi-daemon.service" ];
    environment = {
      ALTSERVER_ANISETTE_SERVER = "https://ani.sidestore.io";
    };
    serviceConfig = {
      ExecStart = "${altserverPkg}/bin/alt-server";
      Restart = "on-failure";
      RestartSec = "30s";
      MemoryMax = "256M";
    };
  };

  # AltServer-Linux 0.0.5 has a broken self-publish path: it shells out to a
  # python3 helper that calls libdns_sd's DNSServiceRegister with name=NULL,
  # which silently fails to propagate via avahi-compat — AND it advertises a
  # different port than it actually listens on (a longstanding 2022-era bug).
  # Sidecar this with avahi-publish reading the real listening port from ss.
  systemd.services.altserver-mdns = {
    description = "Publish _altserver._tcp via avahi (workaround for AltServer's broken self-publish)";
    wantedBy = [ "multi-user.target" ];
    after = [ "altserver.service" ];
    bindsTo = [ "altserver.service" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
      ExecStart = let
        script = pkgs.writeShellScript "altserver-mdns" ''
          set -eu
          for _ in $(seq 1 30); do
            PORT=$(${pkgs.iproute2}/bin/ss -tlnpH 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep alt-server \
              | ${pkgs.gawk}/bin/awk '{print $4}' \
              | ${pkgs.gawk}/bin/awk -F: '{print $NF}' \
              | head -1)
            [ -n "$PORT" ] && break
            sleep 1
          done
          if [ -z "$PORT" ]; then
            echo "altserver listening port not found via ss" >&2
            exit 1
          fi
          echo "Publishing _altserver._tcp on port $PORT"
          exec ${pkgs.avahi}/bin/avahi-publish -s rpi5 _altserver._tcp "$PORT" "serverID=1234567"
        '';
      in toString script;
    };
  };
}
