{ config, pkgs, lib, ... }:
# SideStore self-host stack on rpi5. SideStore (the iOS app) handles its
# own re-signing in-app, but needs an anisette server for Apple-ID tokens
# during the 7-day refresh. We host that here, plus netmuxd + a tailnet
# mDNS bridge so SideStore can use the rpi5-side muxer instead of its
# StosVPN self-tunnel — keeping Tailscale as the only iOS VPN.
#
# Pivoted from the AltServer-Linux setup that previously lived in this
# module: AltServer-Linux 0.0.5 (April 2022, dead) cannot do the initial
# install of SideStore.ipa (only refresh of an already-installed AltStore).
# SideStore.ipa is installed once via the user's Mac (Sideloadly /
# AltServer-Mac); after that, this stack handles refresh forever.
#
# Components:
#   anisette-v3-server (port 6969) — Dadoum's D server (built from source
#     via buildDubPackage). Auto-fetches libCoreADI.so etc. from Apple on
#     first run; ~year-long token caching after the initial 2FA dance.
#   netmuxd — discovers the iPhone via mDNS (_apple-mobdev2._tcp) and
#     bridges its lockdownd protocol. Same binary used previously; the
#     bridge below feeds it tailnet records so it can find the phone
#     off-LAN.
#   sidestore-mdns-bridge — runs avahi-publish-{address,service} to
#     advertise nphone-spoof.local → <iPhone tailnet IP> + a fake
#     _apple-mobdev2._tcp record so netmuxd discovers the iPhone over
#     tailnet (mDNS doesn't propagate across Tailscale; we proved this
#     hack end-to-end before packaging).
#
# The pairing trust record is staged from agenix into
# /var/lib/lockdown/<UDID>.plist at activation time. Same plist worked
# with both AltServer and netmuxd; libimobiledevice's on-disk format
# matches macOS's lockdownd by design.
let
  anisettePkg = pkgs.callPackage ./sidestore/anisette-v3-server.nix { };
  netmuxdPkg  = pkgs.callPackage ./sidestore/netmuxd.nix { };

  # 40-char hex from /var/db/lockdown/<UDID>.plist on the Mac. Set before
  # the first rebuild that intends to talk to the iPhone; activation
  # no-ops while still REPLACE_ME or while the agenix file is absent.
  iPhoneUdid        = "00008030-0004452601FA802E";
  iPhoneTailnetHost = "nphone";

  # Stable spoof hostname published on rpi5's local interface so netmuxd
  # has something to resolve in the fake _apple-mobdev2._tcp record.
  spoofHostname  = "nphone-spoof.local";

  # Fixed advertisement identifier for the spoofed mDNS record. iOS uses
  # a fresh UUID at boot for de-dup; for our purposes anything stable
  # works — netmuxd reads the real UDID via the lockdownd handshake, not
  # from this TXT record.
  spoofIdentifier = "00008030-0004452601FA802E";
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/lockdown 0700 root root -"
    "d /var/lib/anisette 0750 anisette anisette -"
  ];

  users.users.anisette = {
    isSystemUser = true;
    group = "anisette";
    home = "/var/lib/anisette";
  };
  users.groups.anisette = { };

  system.activationScripts.sidestorePairing = lib.stringAfter [ "agenix" ] ''
    if [ "${iPhoneUdid}" != "REPLACE_ME" ] && [ -r /run/agenix/altserver-pairing-plist ]; then
      install -d -m 700 /var/lib/lockdown
      install -m 600 -o root -g root \
        /run/agenix/altserver-pairing-plist \
        /var/lib/lockdown/${iPhoneUdid}.plist
    fi
  '';

  # SideStore takes an anisette *server-list* URL (returning JSON), not a
  # direct anisette URL. Mirror the schema of https://servers.sidestore.io/servers.json
  # and serve it as a static file at /etc/sidestore/servers.json. Tailscale
  # Serve picks up the directory (registry entry on port 6970) and exposes
  # https://rpi5.<tailnet>:6970/servers.json with a Let's Encrypt cert.
  environment.etc."sidestore/servers.json".text = builtins.toJSON {
    servers = [
      { name = "rpi5 self-host"; address = "https://rpi5.gate-mintaka.ts.net:6969"; }
    ];
  };

  # mDNS for two directions: discovering the iPhone via _apple-mobdev2._tcp
  # (consumer, used by netmuxd) AND publishing the spoofed tailnet record
  # via avahi-publish (producer, the bridge service below).
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      userServices = true;
      addresses = true;
    };
  };

  systemd.services.netmuxd = {
    description = "netmuxd — network multiplexer for iOS";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "avahi-daemon.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${netmuxdPkg}/bin/netmuxd --host 127.0.0.1";
      Restart = "on-failure";
      RestartSec = "10s";
      MemoryMax = "128M";
    };
  };

  systemd.services.anisette = {
    description = "anisette-v3-server — Apple ID anisette tokens for SideStore";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${anisettePkg}/bin/anisette-v3-server --host 127.0.0.1 --port 6969 --adi-path /var/lib/anisette";
      User = "anisette";
      Group = "anisette";
      StateDirectory = "anisette";
      Restart = "on-failure";
      RestartSec = "30s";
      MemoryMax = "256M";
    };
  };

  # Tailnet mDNS bridge: Tailscale doesn't propagate mDNS across the
  # tailnet, so when the iPhone is on cellular/foreign WiFi netmuxd
  # can't discover it. We publish a phantom _apple-mobdev2._tcp record
  # on rpi5's local interface pointing at the iPhone's tailnet IP +
  # lockdownd port (62078). netmuxd resolves the spoof hostname → tailnet
  # IP via avahi (we publish the A record too) and connects over
  # tailnet. The pair record staged above lets lockdownd accept us.
  # Verified manually before packaging: device registers, idevicepair
  # --network validate succeeds end-to-end over tailnet only.
  systemd.services.sidestore-mdns-bridge = {
    description = "Spoof _apple-mobdev2._tcp for iPhone tailnet IP (mDNS doesn't cross Tailscale)";
    wantedBy = [ "multi-user.target" ];
    after = [ "avahi-daemon.service" "tailscaled.service" "network-online.target" ];
    wants = [ "avahi-daemon.service" "tailscaled.service" "network-online.target" ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "30s";
      MemoryMax = "32M";
      ExecStart = let
        script = pkgs.writeShellScript "sidestore-mdns-bridge" ''
          set -eu
          IP="$(${pkgs.tailscale}/bin/tailscale ip --4 ${iPhoneTailnetHost} 2>/dev/null || true)"
          if [ -z "$IP" ]; then
            echo "Could not resolve ${iPhoneTailnetHost} tailnet IP — is it logged in to the tailnet?" >&2
            exit 1
          fi
          echo "Publishing ${spoofHostname} → $IP and spoofed _apple-mobdev2._tcp on port 62078"

          ${pkgs.avahi}/bin/avahi-publish-address -R ${spoofHostname} "$IP" &
          ADDR_PID=$!
          trap 'kill $ADDR_PID 2>/dev/null || true' EXIT
          sleep 2

          exec ${pkgs.avahi}/bin/avahi-publish-service \
            -H ${spoofHostname} \
            "nphone-tailnet-spoof" \
            _apple-mobdev2._tcp 62078 \
            "authTag=tailnet-spoof" \
            "identifier=${spoofIdentifier}"
        '';
      in toString script;
    };
  };
}
