{ config, pkgs, lib, ... }:

{
  # iCloud Reminders integration via CalDAV
  # Prerequisites: ICLOUD_EMAIL and ICLOUD_APP_PASSWORD set in ~/.secrets/openclaw.env

  environment.systemPackages = [
    pkgs.vdirsyncer
  ];

  systemd.user = {
    # Sync script
    scripts.icloud-sync-reminders = {
      text = ''
        #!/${pkgs.bash}/bin/bash
        set -euo pipefail

        # Load credentials from openclaw env
        if [ -f ~/.secrets/openclaw.env ]; then
          set -a
          source ~/.secrets/openclaw.env
          set +a
        fi

        # Require credentials
        if [ -z "''${ICLOUD_EMAIL:-}" ] || [ -z "''${ICLOUD_APP_PASSWORD:-}" ]; then
          echo "ERROR: ICLOUD_EMAIL and ICLOUD_APP_PASSWORD not set in ~/.secrets/openclaw.env"
          exit 1
        fi

        # Run vdirsyncer sync
        export HOME=~
        ${pkgs.vdirsyncer}/bin/vdirsyncer sync --force-overwrite=both icloud_reminders 2>&1 | head -50

        # Parse reminders and send to OpenClaw via cron
        REMINDERS_DIR="~/.cache/icloud-reminders/icloud_reminders"
        if [ -d "$REMINDERS_DIR" ]; then
          find "$REMINDERS_DIR" -name "*.ics" -type f | while read -r ics_file; do
            # Extract SUMMARY and DUE from .ics (basic parsing)
            SUMMARY=$(grep "SUMMARY:" "$ics_file" | head -1 | sed 's/SUMMARY://' || echo "Unnamed reminder")
            DUE=$(grep "DUE:" "$ics_file" | head -1 | sed 's/DUE://' || echo "No due date")

            # Send to OpenClaw reminders (via cron API, requires gateway running)
            # Format: OpenClaw system event or direct reminder call
            echo "Synced: $SUMMARY (due: $DUE)"
          done
        fi

        echo "iCloud sync completed"
      '';
      wantedBy = [ "default.target" ];
    };

    # Run every 15 minutes
    timers.icloud-sync-reminders = {
      Unit = {
        Description = "iCloud Reminders sync timer";
      };
      Timer = {
        OnBootSec = "2min";
        OnUnitActiveSec = "15min";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };

    services.icloud-sync-reminders = {
      Unit = {
        Description = "Sync iCloud Reminders via CalDAV";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${config.systemd.user.scripts.icloud-sync-reminders.name}";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };

  # vdirsyncer config (placed in ~/.config/vdirsyncer/config)
  home-manager.users.nsimon = {
    xdg.configFile."vdirsyncer/config".text = ''
      [general]
      status_path = "~/.cache/vdirsyncer"

      [pair icloud_reminders]
      a = "icloud_reminders_local"
      b = "icloud_reminders_remote"
      collections = ["Reminders"]
      metadata = ["color", "displayname"]

      [storage icloud_reminders_local]
      type = "filesystem"
      path = "~/.cache/icloud-reminders/icloud_reminders"
      fileext = ".ics"

      [storage icloud_reminders_remote]
      type = "caldav"
      url = "https://caldav.icloud.com/"
      username.fetch = ["command", "${pkgs.bash}/bin/bash", "-c", "grep ICLOUD_EMAIL ~/.secrets/openclaw.env | cut -d= -f2 | tr -d '\"'"]
      password.fetch = ["command", "${pkgs.bash}/bin/bash", "-c", "grep ICLOUD_APP_PASSWORD ~/.secrets/openclaw.env | cut -d= -f2 | tr -d '\"'"]
      ssl_verify = true
    '';
  };
}
