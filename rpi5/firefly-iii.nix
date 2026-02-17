{
  config,
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
      APP_URL = "http://localhost:8080";
      SITE_OWNER = "${username}@localhost";

      # APP_KEY must be exactly 32 characters - generate with:
      # head -c 32 /dev/urandom | base64 | head -c 32
      # Store it in this file (create the file manually):
      APP_KEY_FILE = "/var/lib/firefly-iii/app-key.txt";

      # SQLite database (simplest setup, no external DB needed)
      DB_CONNECTION = "sqlite";

      # Trusted proxies for reverse proxy setups
      TRUSTED_PROXIES = "**";

      # Timezone
      TZ = config.time.timeZone;

      # Disable telemetry
      SEND_TELEMETRY = false;
    };
  };

  # TrueLayer2Firefly - Open Banking sync for Firefly III
  # https://github.com/erwindouna/truelayer2firefly
  # Custom entrypoint adds fr-stet-societe-generale (Société Générale) to the
  # TrueLayer provider list at container startup, then runs the original CMD.
  virtualisation.oci-containers.containers.truelayer2firefly = {
    image = "erwind/truelayer2firefly:latest";
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

        exec poetry run uvicorn truelayer2firefly:app --host 0.0.0.0 --port 3000
      ''
    ];
    # Use host networking so the container can reach Firefly III on localhost:8080
    extraOptions = [
      "--name=truelayer2firefly"
      "--network=host"
    ];
  };

  # Serve Firefly III on port 8080 instead of 80
  services.nginx.virtualHosts."firefly.local" = {
    listen = [
      {
        addr = "0.0.0.0";
        port = 8080;
      }
    ];
  };

  # Open firewall for local access
  networking.firewall.allowedTCPPorts = [
    8080 # Firefly III (nginx)
    3000 # TrueLayer2Firefly
  ];

  # Automatically generate APP_KEY if it doesn't exist and ensure correct ownership
  system.activationScripts.firefly-iii-app-key = ''
    mkdir -p /var/lib/firefly-iii
    mkdir -p /var/lib/truelayer2firefly
    if [ ! -f /var/lib/firefly-iii/app-key.txt ]; then
      echo "Generating Firefly III APP_KEY..."
      # Generate a 32-character base64 key
      head -c 32 /dev/urandom | base64 | head -c 32 > /var/lib/firefly-iii/app-key.txt
      echo "APP_KEY generated successfully"
    fi
    # Always ensure correct permissions and ownership
    chmod 600 /var/lib/firefly-iii/app-key.txt
    chown firefly-iii:firefly-iii /var/lib/firefly-iii/app-key.txt 2>/dev/null || true
  '';
}
