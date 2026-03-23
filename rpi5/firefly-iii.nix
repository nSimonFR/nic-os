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
      APP_URL = "https://rpi5:8080";
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

  # Build truelayer2firefly Docker image from source (no public arm64 image available)
  systemd.services.truelayer2firefly-build = {
    description = "Build truelayer2firefly Docker image";
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    after = [ "docker.service" ];
    unitConfig.ConditionPathExists = "!/var/lib/truelayer2firefly/.image-built";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.docker}/bin/docker build https://github.com/erwindouna/truelayer2firefly.git -t truelayer2firefly:arm64";
      ExecStartPost = [
        "${pkgs.coreutils}/bin/mkdir -p /var/lib/truelayer2firefly"
        "${pkgs.coreutils}/bin/touch /var/lib/truelayer2firefly/.image-built"
      ];
    };
  };
  systemd.services."docker-truelayer2firefly".requires = [ "truelayer2firefly-build.service" ];
  systemd.services."docker-truelayer2firefly".after = [ "truelayer2firefly-build.service" ];

  # TrueLayer2Firefly - Open Banking sync for Firefly III
  # https://github.com/erwindouna/truelayer2firefly
  # Custom entrypoint adds fr-stet-societe-generale (Société Générale) to the
  # TrueLayer provider list at container startup, then runs the original CMD.
  virtualisation.oci-containers.containers.truelayer2firefly = {
    image = "truelayer2firefly:arm64";
    volumes = [
      "/var/lib/truelayer2firefly:/app/data"
    ];
    entrypoint = "/bin/sh";
    cmd = [
      "-c"
      ''
        # Add Société Générale to the TrueLayer provider list
        sed -i 's/ee-xs2a-all"/ee-xs2a-all fr-stet-societe-generale"/' /app/clients/truelayer.py

        # Fix stale-credential bug in exchange_authorization_code():
        # The method captures self.client_secret (set at init) into params BEFORE
        # _request() re-reads the current config value. After rotating a secret or
        # reconfiguring, the exchange sends the OLD credentials → invalid_client.
        # Patch: read directly from config, consistent with _refresh_token().
        sed -i 's/"client_id": self.client_id,/"client_id": self._config.get("truelayer_client_id"),/' /app/clients/truelayer.py
        sed -i 's/"client_secret": self.client_secret,/"client_secret": self._config.get("truelayer_client_secret"),/' /app/clients/truelayer.py
        sed -i 's/"redirect_uri": self.redirect_uri,$/"redirect_uri": self._config.get("truelayer_redirect_uri"),/' /app/clients/truelayer.py

        # Fix NoneType crash for credit transactions without IBAN (GitHub PR #159):
        # When linked_account is None, source_id and source_name would crash with
        # "'NoneType' object is not subscriptable". The destination fields already
        # had None checks but the source fields did not.
        sed -i '/"source_id": (/{n;s/linked_account\["id"\]/(None if linked_account is None else linked_account["id"])/;}' /app/importer2firefly.py
        sed -i '/"source_name": (/{n;s/linked_account\["attributes"\]\["name"\]/("(unknown revenue account)" if linked_account is None else linked_account["attributes"]["name"])/;}' /app/importer2firefly.py

        exec poetry run uvicorn truelayer2firefly:app --host 0.0.0.0 --port 8081
      ''
    ];
    # Use host networking so the container can reach Firefly III on localhost:8080
    extraOptions = [
      "--name=truelayer2firefly"
      "--network=host"
    ];
  };

  # ── Prometheus blackbox probes ───────────────────────────────────────
  services.prometheus.scrapeConfigs = [{
    job_name       = "blackbox-firefly";
    metrics_path   = "/probe";
    params         = { module = [ "http_2xx" ]; };
    static_configs = [{ targets = [
      "http://127.0.0.1:8082"   # firefly-iii
      "http://127.0.0.1:8081"   # truelayer2firefly
    ]; }];
    relabel_configs = [
      { source_labels = [ "__address__" ]; target_label = "__param_target"; }
      { source_labels = [ "__param_target" ]; target_label = "instance"; }
      { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
    ];
  }];

  # Ensure data directories exist for Firefly III and TrueLayer
  system.activationScripts.firefly-iii-dirs = ''
    mkdir -p /var/lib/firefly-iii
    mkdir -p /var/lib/truelayer2firefly
  '';
}
