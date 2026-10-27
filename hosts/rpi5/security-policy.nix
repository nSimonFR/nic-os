# Security invariants, checked at eval time so CI refuses to deploy a config
# that breaks one. Everything here is about what the LAN and the internet can
# reach; tailnet-only exposure is policed by nic.services.*.public instead
# (an internet-reachable service must set authenticated = true).
{ config, lib, ... }:

let
  fw  = config.networking.firewall;
  ssh = config.services.openssh.settings;

  # What the LAN may reach. 22 = sshd (keys only, below), 53 = blocky,
  # 41641/udp = tailscale NAT traversal.
  lanTcp = [ 22 53 ];
  lanUdp = [ 53 41641 ];

  extra = allowed: ports: lib.subtractLists allowed ports;

  # sudo may admit nsimon only on the root-only TOTP (sudo-totp.nix), optionally
  # preceded by an SSH-agent signature checked against a root-owned key file
  # (sudo-ssh-agent.nix); then pam_deny, with no session cache.
  sudoAuth = lib.filter (l: lib.hasPrefix "auth " l)
    (lib.splitString "\n" config.security.pam.services.sudo.text);
  rsshRule = "auth sufficient [^ ]*/libpam_rssh\\.so auth_key_file=/etc/ssh/sudo_keys/\\$ruser( #.*)?";
  totpRule = "auth sufficient [^ ]*/pam_google_authenticator\\.so secret=/var/lib/sudo-totp/\\$\\{USER} user=root( #.*)?";
  denyRule = "auth required [^ ]*/pam_deny\\.so( #.*)?";
  matches = rules: builtins.length sudoAuth == builtins.length rules
    && lib.all (p: builtins.match p.fst p.snd != null) (lib.zipLists rules sudoAuth);
  sudoHumanOnly = (matches [ totpRule denyRule ] || matches [ rsshRule totpRule denyRule ])
    && lib.hasInfix "Defaults:nsimon timestamp_timeout=0" config.security.sudo.extraConfig;

  # Per-interface openings bypass the global lists; only the tailnet may have them.
  nonTailnetIfaces = lib.filterAttrs (n: _: n != "tailscale0") fw.interfaces;
  ifaceOpenings = lib.concatLists (lib.mapAttrsToList (n: i:
    lib.optional
      (i.allowedTCPPorts != [ ] || i.allowedUDPPorts != [ ]
        || i.allowedTCPPortRanges != [ ] || i.allowedUDPPortRanges != [ ])
      n) nonTailnetIfaces);
in
{
  assertions = [
    {
      assertion = fw.enable;
      message = "security-policy: networking.firewall must stay enabled.";
    }
    {
      assertion = extra lanTcp fw.allowedTCPPorts == [ ]
        && extra lanUdp fw.allowedUDPPorts == [ ]
        && fw.allowedTCPPortRanges == [ ] && fw.allowedUDPPortRanges == [ ];
      message =
        "security-policy: a module opened a port to the LAN: tcp "
        + toString (extra lanTcp fw.allowedTCPPorts) + " udp "
        + toString (extra lanUdp fw.allowedUDPPorts)
        + ". Use networking.firewall.interfaces.tailscale0 (or openFirewall = false), "
        + "or add it to lanTcp/lanUdp in hosts/rpi5/security-policy.nix on purpose.";
    }
    {
      assertion = ifaceOpenings == [ ];
      message =
        "security-policy: ports opened on non-tailnet interface(s) "
        + toString ifaceOpenings + ".";
    }
    {
      assertion = extra [ "tailscale0" "lo" ] fw.trustedInterfaces == [ ];
      message =
        "security-policy: only tailscale0 may be a trusted interface, got "
        + toString fw.trustedInterfaces + ".";
    }
    {
      assertion = ssh.PasswordAuthentication == false
        && ssh.KbdInteractiveAuthentication == false
        && ssh.PermitRootLogin == "no";
      message =
        "security-policy: sshd must be keys-only with no root login "
        + "(PasswordAuthentication, KbdInteractiveAuthentication = false; PermitRootLogin = \"no\").";
    }
    {
      assertion = config.users.users.root.openssh.authorizedKeys.keys == [ ]
        && config.users.users.root.openssh.authorizedKeys.keyFiles == [ ];
      message = "security-policy: root must have no SSH authorized keys.";
    }
    # Agents run as nsimon and Agent Vault's keys are root-only, so nsimon must
    # have no path to root but a TOTP code or Mac-approved signature from the user.
    {
      # extraRules always holds NixOS's own %wheel rule, so look for nsimon by name.
      assertion = !(lib.elem "wheel" config.users.users.nsimon.extraGroups)
        && !(lib.elem "nsimon" config.users.groups.wheel.members)
        && !(lib.elem "nsimon" config.nix.settings.trusted-users)
        && (sudoHumanOnly || !(lib.any (r: lib.elem "nsimon" (r.users or [ ])) config.security.sudo.extraRules));
      message = "security-policy: nsimon must not be in wheel or a trusted nix user, and may be in "
        + "a sudo rule only behind sudo-totp.nix (and sudo-ssh-agent.nix) with no session cache.";
    }
  ];
}
