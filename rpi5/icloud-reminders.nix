{ config, pkgs, lib, ... }:

{
  options.services.icloud-reminders = {
    enable = lib.mkEnableOption "iCloud Reminders sync via vdirsyncer";
  };

  config = lib.mkIf config.services.icloud-reminders.enable {
    # Install vdirsyncer
    environment.systemPackages = [ pkgs.vdirsyncer ];

    # vdirsyncer configuration
    home-manager.users.nsimon.xdg.configFile."vdirsyncer/config".text = ''
      [general]
      status_path = "~/.cache/vdirsyncer"

      [pair icloud_reminders]
      a = "icloud_reminders_local"
      b = "icloud_reminders_remote"
      collections = ["Reminders"]
      metadata = ["color", "displayname"]

      [storage icloud_reminders_local]
      type = "filesystem"
      path = "~/.cache/icloud-reminders"
      fileext = ".ics"

      [storage icloud_reminders_remote]
      type = "caldav"
      # Manually configure with your iCloud credentials
      # Format: https://ICLOUD_EMAIL:ICLOUD_APP_PASSWORD@caldav.icloud.com/calendars/caldav/Reminders/
      # Example: https://you@icloud.com:xxxx-xxxx-xxxx-xxxx@caldav.icloud.com/calendars/caldav/Reminders/
      # WARNING: Do not commit plaintext credentials. Use vdirsyncer discover + interactive auth instead.
      ssl_verify = true
    '';
  };
}
