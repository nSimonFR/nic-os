# hosts/rpi5/sudo-totp.nix
#
# sudo for nsimon on a 6-digit TOTP code instead of a password: the user reads
# it on their phone and hands it to an agent (`printf '%s\n' CODE | sudo -S -p '' cmd`).
# Agents run as nsimon, so the secret is root-only (`user=root`), each code works
# once, and sudo caches nothing: one code, one command, ~90 s of validity.
#
# Enrolment, once, as root: `DRY_RUN=0 sudo-totp-enroll` (sudo_totp.py) puts the
# secret in Vaultwarden's Agents org; clone it to your vault, delete it, then
# `vault-agent purge --name "rpi5 sudo (TOTP)"`. Until then sudo fails
# closed (no `nullok`). Re-enrol: delete /var/lib/sudo-totp/nsimon first.
{ pkgs, ... }:
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

  environment.systemPackages = [ pkgs.nicos-scripts ]; # sudo-totp-enroll

  systemd.tmpfiles.rules = [ "d ${secretDir} 0700 root root -" ];
}
