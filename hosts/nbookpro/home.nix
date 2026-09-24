{ username, unstablePkgs, ... }:
{
  imports = [
    ./applications-patch.nix
  ];

  home = {
    username = username;
    homeDirectory = "/Users/${username}";

    sessionVariables = {
      SSH_AUTH_SOCK = "$HOME/.bitwarden-ssh-agent.sock";
    };
  };

  # Deliberately off PATH: only inf-stg / inf-prod (dotfiles/zsh/trusk.zsh) run it.
  # A fixed path, not an env var: HM session vars are skipped by shells that
  # inherit their once-only guard (herdr panes, agent shells).
  home.file.".local/libexec/infisical".source = "${unstablePkgs.infisical}/bin/infisical";
}
