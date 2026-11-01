# Who may do what: the eval-time security policy, root access, agent credentials, the password vault.
{
  imports = [
    ./security-policy.nix
    ./agent-access.nix
    ./sudo-totp.nix
    ./sudo-ssh-agent.nix
    ./death-plan-switch.nix
    ./vaultwarden.nix
    ./agent-vault.nix
  ];
}
