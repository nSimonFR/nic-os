{ config, pkgs, lib, telegramChatId, ... }:
let
  voicemailPort = 8340;
  srcDir = ./voicemail-assistant;

  # Python environment with pip for installing pipecat from requirements.txt
  python = pkgs.python312;

  # Startup script: ensure venv exists, install deps, run server
  startScript = pkgs.writeShellScript "voicemail-assistant-start" ''
    set -euo pipefail

    VENV="/var/lib/voicemail-assistant/venv"

    if [ ! -d "$VENV" ]; then
      ${python}/bin/python3 -m venv "$VENV"
    fi

    # Install/upgrade dependencies
    "$VENV/bin/pip" install --quiet --upgrade -r ${srcDir}/requirements.txt

    # Run the webhook server
    exec "$VENV/bin/python" ${srcDir}/server.py
  '';
in
{
  # ── Voicemail Assistant ────────────────────────────────────────────────────
  # Pipecat + Gemini Live S2S voicemail bot.
  # Webhook server on 127.0.0.1:${toString voicemailPort} receives inbound
  # call notifications from Daily SIP, spawns a bot per call.

  systemd.services.voicemail-assistant = {
    description = "Voicemail Assistant (Pipecat + Gemini Live)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    environment = {
      VOICEMAIL_PORT = toString voicemailPort;
      TELEGRAM_CHAT_ID = toString telegramChatId;
    };

    serviceConfig = {
      ExecStart = startScript;
      DynamicUser = true;
      StateDirectory = "voicemail-assistant";
      WorkingDirectory = "/var/lib/voicemail-assistant";
      Restart = "on-failure";
      RestartSec = "10s";

      # Read API keys from agenix secrets
      EnvironmentFile = [
        config.age.secrets.voicemail-env.path
      ];

      # Hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ "/var/lib/voicemail-assistant" ];
    };
  };
}
