{ pkgs, lib, username, unstablePkgs, tailnetFqdn, ... }:
{
  imports = [
    ./applications-patch.nix
    ./linear-t3-relay.nix
    ./entire-brain.nix
    ./sudo-agent-forward.nix
  ];

  home = {
    username = username;
    homeDirectory = "/Users/${username}";

    # T3 Code desktop with the Issues page; replaces the manually installed nightly.
    packages = [
      pkgs.t3code-desktop
      (pkgs.writeShellApplication {
        name = "entire-trusk-enable";
        runtimeInputs = [ (pkgs.callPackage ../../pkgs/cli/entire.nix { }) pkgs.git pkgs.jq ];
        text = builtins.readFile ./scripts/entire-trusk-enable.sh;
      })
    ];

    sessionVariables = {
      SSH_AUTH_SOCK = "$HOME/.bitwarden-ssh-agent.sock";
    };
  };

  # SessionStart hook (dotfiles/claude-settings.json): Claude Code's Bash commands go
  # through the rpi5's Agent Vault (hosts/rpi5/agent-vault.nix) over the tailnet, with
  # Hermes' proxy env, so they hold placeholders (`__linear_key__`), never the keys.
  # Kept direct: GitHub (the vault would attach nSimonFR-ai, blind to trusk-official),
  # and only the personal tailnet, not `.ts.net`: the work kube API has its own proxy.
  # The last fetch is reused when the Pi is unreachable.
  home.file.".claude/hooks/agent-vault-env" = {
    executable = true;
    source = pkgs.writeShellScript "agent-vault-env" ''
      [ -n "''${CLAUDE_ENV_FILE:-}" ] || exit 0
      d=~/.config/agent-vault
      umask 077
      mkdir -p "$d"
      ssh=(/usr/bin/ssh -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=5 nsimon@rpi5)
      if "''${ssh[@]}" cat /var/lib/agent-vault-hermes/ca-bundle.pem > "$d/ca.pem.tmp" \
        && "''${ssh[@]}" cat /var/lib/agent-vault-hermes/proxy.env > "$d/proxy.env.tmp" \
        && [ -s "$d/ca.pem.tmp" ] && [ -s "$d/proxy.env.tmp" ]; then
        mv "$d/ca.pem.tmp" "$d/ca.pem"
        ${pkgs.gnused}/bin/sed \
          -e 's/@127\.0\.0\.1:/@${tailnetFqdn}:/' \
          -e "s#/var/lib/agent-vault-hermes/ca-bundle.pem#$d/ca.pem#" \
          -e '/^no_proxy=/I s/,\.ts\.net/,${lib.removePrefix "rpi5" tailnetFqdn}/' \
          -e '/^no_proxy=/I s/$/,github.com,api.github.com,uploads.github.com/' \
          -e 's/^/export /' "$d/proxy.env.tmp" > "$d/proxy.env"
        echo "export NIX_SSL_CERT_FILE=$d/ca.pem" >> "$d/proxy.env"
      fi
      rm -f "$d"/*.tmp
      [ -r "$d/proxy.env" ] && cat "$d/proxy.env" >> "$CLAUDE_ENV_FILE"
      exit 0
    '';
  };

  # Deliberately off PATH: only inf-stg / inf-prod (private trusk checkout's zsh/trusk.zsh) run it.
  # A fixed path, not an env var: HM session vars are skipped by shells that
  # inherit their once-only guard (herdr panes, agent shells).
  home.file.".local/libexec/infisical".source = "${unstablePkgs.infisical}/bin/infisical";
}
