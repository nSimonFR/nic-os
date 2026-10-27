# rootreq — one command as root, approved on the phone. Agents have no sudo
# (security-policy.nix); `rootreq -- cmd args…` asks rootreq-broker, which
# posts the command to Telegram through the existing bot (send-only: Hermes
# polls it) with a link to an approval page on the tailnet. Only nPhone, logged
# in as the approver, may decide: the rpi5 and the Mac are both reachable by
# agents. See nicos_scripts/security/rootreq.py.
{ pkgs, tailnetFqdn, telegramChatId, ... }:
let
  port = 8390;
  certDir = "/var/lib/rootreq";
in
{
  environment.systemPackages = [ pkgs.nicos-scripts ];

  systemd.services.rootreq-broker = {
    description = "rootreq: root commands approved from the phone";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.tailscale ];
    environment = {
      ROOTREQ_SOCKET = "/run/rootreq/rootreq.sock";
      # The firewall admits LAN traffic on 22/53 only (security-policy.nix), so
      # this is the tailnet plus localhost; localhost fails the whois check.
      ROOTREQ_LISTEN_HOST = "0.0.0.0";
      ROOTREQ_LISTEN_PORT = toString port;
      ROOTREQ_PUBLIC_URL = "https://${tailnetFqdn}:${toString port}";
      ROOTREQ_TLS_CERT = "${certDir}/cert.pem";
      ROOTREQ_TLS_KEY = "${certDir}/key.pem";
      ROOTREQ_ALLOWED_UID = "1001"; # nsimon
      ROOTREQ_APPROVER_LOGIN = "nSimonFR@github";
      ROOTREQ_APPROVER_NODE = "nphone.gate-mintaka.ts.net";
      TELEGRAM_TOKEN_FILE = "/run/agenix/telegram-bot-token";
      TELEGRAM_CHAT_ID = toString telegramChatId;
    };
    serviceConfig = {
      # Tailnet's Let's Encrypt cert (90 days); tailscaled renews it when it's near expiry.
      ExecStartPre = "${pkgs.tailscale}/bin/tailscale cert --cert-file ${certDir}/cert.pem --key-file ${certDir}/key.pem ${tailnetFqdn}";
      ExecStart = "${pkgs.nicos-scripts}/bin/rootreq-broker";
      StateDirectory = "rootreq";
      StateDirectoryMode = "0700";
      RuntimeMaxSec = "7d"; # restart (Restart=always) to pick up a renewed cert
      RuntimeDirectory = "rootreq";
      RuntimeDirectoryMode = "0755";
      Restart = "always";
      RestartSec = 5;
    };
  };
}
