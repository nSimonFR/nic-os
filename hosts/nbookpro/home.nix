{ pkgs, username, unstablePkgs, ... }:
{
  imports = [
    ./applications-patch.nix
    ./linear-t3-relay.nix
  ];

  home = {
    username = username;
    homeDirectory = "/Users/${username}";

    # T3 Code desktop with the Issues page; replaces the manually installed nightly.
    packages = [ pkgs.t3code-desktop ];

    sessionVariables = {
      SSH_AUTH_SOCK = "$HOME/.bitwarden-ssh-agent.sock";
    };
  };

  # Deliberately off PATH: only inf-stg / inf-prod (private trusk checkout's zsh/trusk.zsh) run it.
  # A fixed path, not an env var: HM session vars are skipped by shells that
  # inherit their once-only guard (herdr panes, agent shells).
  home.file.".local/libexec/infisical".source = "${unstablePkgs.infisical}/bin/infisical";
}
