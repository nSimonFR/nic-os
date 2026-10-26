# hosts/rpi5/sudo-totp.nix
#
# sudo for nsimon on a 6-digit TOTP code instead of a password: the user reads
# it on their phone and hands it to an agent (`printf '%s\n' CODE | sudo -S -p '' cmd`).
# Agents run as nsimon, so the secret is root-only (`user=root`), each code works
# once, and sudo caches nothing: one code, one command, ~90 s of validity.
#
# Enrolment: `rootreq -- systemctl start sudo-totp-enroll` (sudo_totp.py) puts
# the secret in Vaultwarden's Agents org; clone it to your vault, delete it,
# then `vault-agent purge --name "rpi5 sudo (TOTP)"`. Until then sudo fails
# closed (no `nullok`). Re-enrol: delete /var/lib/sudo-totp/nsimon first.
{ config, pkgs, username, ... }:
let
  secretDir = "/var/lib/sudo-totp";
in
{
  security.pam.services.sudo = {
    unixAuth = false; # no password path around the code
    rules.auth.totp = {
      order = 11600; # before unix (11700, off) and the closing pam_deny
      control = "sufficient";
      modulePath = "${pkgs.google-authenticator}/lib/security/pam_google_authenticator.so";
      args = [ "secret=${secretDir}/\${USER}" "user=root" ];
    };
  };

  security.sudo.extraRules = [{
    users = [ "nsimon" ];
    commands = [{ command = "ALL"; }];
  }];
  # A cached sudo would turn one code into minutes of root for every agent.
  security.sudo.extraConfig = ''
    Defaults:nsimon timestamp_timeout=0
  '';

  systemd.tmpfiles.rules = [ "d ${secretDir} 0700 root root -" ];

  systemd.services.sudo-totp-enroll = {
    description = "Create nsimon's sudo TOTP secret and hand it over through Vaultwarden";
    after = [ "vaultwarden.service" ];
    requires = [ "vaultwarden.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.nicos-scripts}/bin/sudo-totp-enroll";
    };
    environment = {
      SUDO_TOTP_DIR = secretDir;
      SUDO_TOTP_USER = username;
      DRY_RUN = "0";
      VAULT_URL = "http://127.0.0.1:8222/vaultwarden";
      # As vaultwarden.nix's vault-agent wrapper.
      VAULT_AGENT_EMAIL = "${username}+agents@pm.me";
      VAULT_OWNER_EMAIL = "${username}@pm.me";
      VAULT_AGENT_PASSWORD_FILE = config.age.secrets.vaultwarden-agent-password.path;
    };
  };
}
