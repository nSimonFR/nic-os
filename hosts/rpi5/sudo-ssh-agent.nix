# hosts/rpi5/sudo-ssh-agent.nix
#
# sudo on a Bitwarden SSH-agent signature, for when the user is at the Mac:
# the Mac reverse-forwards its Bitwarden agent to `agentSock`
# (hosts/nbookpro/sudo-agent-forward.nix) and `mac-sudo cmd` points pam_rssh
# at it. Plain `sudo` never asks the Mac, so the phone's TOTP path
# (sudo-totp.nix) can't stall on a prompt nobody is there to answer; a refused
# or missing signature falls through to TOTP.
#
# Bitwarden must ask on every use (Settings → SSH agent → "Always"): anything
# running as nsimon can reach the socket, so a remembered approval is silent root.
{ lib, pkgs, ... }:
let
  # The sudo key: its own Bitwarden SSH key item, never a login key.
  sudoKeys = [ ];
  # The Mac's on-disk tunnel key, allowed to forward a socket and nothing else.
  tunnelKeys = [ ];
  agentSock = "/home/nsimon/.ssh/sudo-agent.sock";
in
lib.mkIf (sudoKeys != [ ]) {
  security.pam.rssh = {
    enable = true;
    # Root-owned: a user-writable key file would let nsimon enrol its own key.
    settings.auth_key_file = "/etc/ssh/sudo_keys/$ruser";
  };
  security.pam.services.sudo.rssh = true;
  environment.etc."ssh/sudo_keys/nsimon".text = lib.concatLines sudoKeys;

  users.users.nsimon.openssh.authorizedKeys.keys =
    map (k: ''restrict,port-forwarding,command="${pkgs.coreutils}/bin/false" ${k}'') tunnelKeys;
  # A reconnect replaces the socket the dropped session left behind.
  services.openssh.settings.StreamLocalBindUnlink = true;

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "mac-sudo";
      text = ''SSH_AUTH_SOCK=${agentSock} exec /run/wrappers/bin/sudo "$@"'';
    })
  ];
}
