# rootreq — one command as root, approved on the phone. Agents have no sudo
# (security-policy.nix); `rootreq -- cmd args…` asks rootreq-broker, which
# posts the command to Telegram through the existing bot (send-only: Hermes
# polls it) with a link to an approval page on the tailnet. Only nPhone, logged
# in as the approver, may decide: the rpi5 and the Mac are both reachable by
# agents. See nicos_scripts/security/rootreq.py.
{ pkgs, tailnetFqdn, telegramChatId, ... }:
let
  port = 8390;
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
      ROOTREQ_PUBLIC_URL = "http://${tailnetFqdn}:${toString port}";
      ROOTREQ_ALLOWED_UID = "1001"; # nsimon
      ROOTREQ_APPROVER_LOGIN = "nSimonFR@github";
      ROOTREQ_APPROVER_NODE = "nphone.gate-mintaka.ts.net";
      TELEGRAM_TOKEN_FILE = "/run/agenix/telegram-bot-token";
      TELEGRAM_CHAT_ID = toString telegramChatId;
    };
    serviceConfig = {
      ExecStart = "${pkgs.nicos-scripts}/bin/rootreq-broker";
      RuntimeDirectory = "rootreq";
      RuntimeDirectoryMode = "0755";
      Restart = "always";
      RestartSec = 5;
    };
  };
}
