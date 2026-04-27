{ config, lib, pkgs, ... }:
# Hydroxide — third-party ProtonMail bridge exposing IMAP / SMTP / CardDAV.
# IMAP/SMTP exposed only on tailscale0; CardDAV stays on 127.0.0.1 and is
# proxied via Tailscale Serve (see services-registry.nix).
#
# FIRST-TIME SETUP (auth.json must be created interactively before the
# daemon can serve any requests — the service will crashloop until then):
#
#   1. systemctl stop hydroxide
#   2. sudo -u hydroxide -H \
#        XDG_CONFIG_HOME=/var/lib/hydroxide/.config \
#        hydroxide auth <user>@protonmail.com
#      → enter Proton password, TOTP, mailbox password if prompted.
#      → CAPTURE the printed bridge password — it cannot be recovered.
#   3. systemctl start hydroxide
#
# Mail clients log in with the bridge password (NOT the Proton account
# password). Plaintext on tailnet is fine — tailnet is encrypted.
let
  smtpPort    = 1025;
  imapPort    = 1143;
  carddavPort = 8083;  # default 8080 collides with nginx/firefly
in
{
  users.users.hydroxide  = {
    isSystemUser = true;
    group = "hydroxide";
    home  = "/var/lib/hydroxide";
  };
  users.groups.hydroxide = {};

  systemd.tmpfiles.rules = [
    "d /var/lib/hydroxide          0700 hydroxide hydroxide - -"
    "d /var/lib/hydroxide/.config  0700 hydroxide hydroxide - -"
  ];

  systemd.services.hydroxide = {
    description = "Hydroxide ProtonMail bridge";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];

    environment.XDG_CONFIG_HOME = "/var/lib/hydroxide/.config";

    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.hydroxide}/bin/hydroxide"
        "-smtp-host"    "0.0.0.0"
        "-smtp-port"    (toString smtpPort)
        "-imap-host"    "0.0.0.0"
        "-imap-port"    (toString imapPort)
        "-carddav-host" "127.0.0.1"
        "-carddav-port" (toString carddavPort)
        "serve"
      ];
      User           = "hydroxide";
      Group          = "hydroxide";
      Restart        = "on-failure";
      RestartSec     = "10";
      ReadWritePaths = [ "/var/lib/hydroxide" ];
      LimitNOFILE    = 65536;
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    imapPort
    smtpPort
  ];
}
