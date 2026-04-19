{ config, lib, pkgs, telegramChatId, ... }:

{
  services.scrutiny = {
    enable = true;
    influxdb.enable = true;

    settings = {
      web.listen = {
        # Port 9090 is reserved for Prometheus; use 9099 here.
        port = 9099;
        host = "127.0.0.1";
      };

      # Telegram notification URL assembled at runtime; see ExecStartPre below.
      notify.urls = [
        { _secret = "/run/scrutiny/telegram-url"; }
      ];
    };

    collector = {
      enable = true;
      # Collect SMART data once per day; timer is persistent (catches missed runs).
      schedule = "daily";
    };
  };

  # Compose the Telegram notification URL at runtime from the existing bot token secret
  # and an inline chat ID (not sensitive). This privileged ExecStartPre (+) runs as root
  # before the module's own preStart (which processes _secret substitutions), so the
  # telegram-url file is ready when genJqSecretsReplacementSnippet reads it.
  # ── InfluxDB memory optimization ───────────────────────────────────────────
  # InfluxDB defaults are tuned for large servers; GOMEMLIMIT makes Go GC
  # reclaim earlier. Only stores daily SMART data — minimal working set.
  systemd.services.influxdb2.environment.GOMEMLIMIT = "80MiB";

  systemd.services.scrutiny.serviceConfig.ExecStartPre = lib.mkBefore [
    ("+${pkgs.writeShellScript "scrutiny-compose-telegram-url" ''
      token=$(< ${config.age.secrets.telegram-bot-token.path})
      printf 'telegram://%s@telegram?channels=${toString telegramChatId}\n' "$token" \
        > /run/scrutiny/telegram-url
      # 644 is safe: /run/scrutiny/ is mode 0700 owned by the DynamicUser,
      # so no other unprivileged process can traverse into it.
      chmod 644 /run/scrutiny/telegram-url
    ''}")
  ];
}
