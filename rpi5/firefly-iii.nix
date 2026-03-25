{
  config,
  lib,
  pkgs,
  username,
  ...
}:
{
  # Firefly III - Personal Finance Manager
  # https://www.firefly-iii.org/
  services.firefly-iii = {
    enable = true;

    # Virtual host for nginx (serves on port 8080)
    virtualHost = "firefly.local";
    enableNginx = true;

    settings = {
      APP_ENV = "local";
      # Accessed via nginx portal on port 8080; APP_URL is the external base.
      # With TRUSTED_PROXIES="**", X-Forwarded-* headers override this for dynamic requests.
      # Note: APP_SUBDIRECTORY is not supported in Firefly III 6.4.14.
      APP_URL = "https://rpi5.gate-mintaka.ts.net:8080";
      SITE_OWNER = "${username}@localhost";

      # APP_KEY: generate with: echo "base64:$(head -c 32 /dev/urandom | base64)"
      # The nixpkgs module reads this file and sets APP_KEY at service start.
      APP_KEY_FILE = "/run/agenix/firefly-app-key";

      # SQLite database (simplest setup, no external DB needed)
      DB_CONNECTION = "sqlite";

      # Trusted proxies for reverse proxy setups (Tailscale Serve terminates TLS)
      TRUSTED_PROXIES = "**";

      # Timezone
      TZ = config.time.timeZone;

      # Disable telemetry — must be a string "false", not a Nix bool (bool false → empty string)
      SEND_TELEMETRY = "false";
    };
  };

  # PrivateUsers = true (set by nixpkgs commonServiceConfig) requires user namespace support.
  # Override to false for RPi5 compatibility until confirmed working.
  systemd.services.firefly-iii-setup.serviceConfig.PrivateUsers = lib.mkForce false;
  systemd.services.firefly-iii-cron.serviceConfig.PrivateUsers = lib.mkForce false;

  # ── Prometheus blackbox probes ───────────────────────────────────────
  services.prometheus.scrapeConfigs = [{
    job_name       = "blackbox-firefly";
    metrics_path   = "/probe";
    params         = { module = [ "http_2xx" ]; };
    static_configs = [{ targets = [
      "http://127.0.0.1:8082"   # firefly-iii
    ]; }];
    relabel_configs = [
      { source_labels = [ "__address__" ]; target_label = "__param_target"; }
      { source_labels = [ "__param_target" ]; target_label = "instance"; }
      { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
    ];
  }];

  system.activationScripts.firefly-iii-dirs = ''
    mkdir -p /var/lib/firefly-iii
  '';
}
