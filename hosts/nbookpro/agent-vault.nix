# Agent Vault (hosts/rpi5/security/agent-vault.nix) on the Mac: opt-in, never a global proxy.
#
# The vault MITMs everything it proxies and the Pi reaches less than the Mac does
# (not the work tailnet), so a session-wide HTTPS_PROXY broke every host the Pi
# can't see, with a misleading x509 (2026-11-03). A session only gets
# AGENT_VAULT_ENV; a skill that needs a brokered key sources it in the same
# command as its call, exactly like on the Pi (shared/skills/linear, ryot).
# The last fetch is reused when the Pi is unreachable.
{
  config,
  pkgs,
  tailnetFqdn,
  ...
}:
let
  dir = "${config.home.homeDirectory}/.config/agent-vault";
  hook = pkgs.writeShellScript "agent-vault-env" ''
    [ -n "''${CLAUDE_ENV_FILE:-}" ] || exit 0
    d=${dir}
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
        "$d/proxy.env.tmp" > "$d/proxy.env"
      echo "NIX_SSL_CERT_FILE=$d/ca.pem" >> "$d/proxy.env"
    fi
    rm -f "$d"/*.tmp
    [ -r "$d/proxy.env" ] && echo "export AGENT_VAULT_ENV=$d/proxy.env" >> "$CLAUDE_ENV_FILE"
    exit 0
  '';
in
{
  # SessionStart hook, wired in home/dotfiles/claude-settings.json.
  home.file.".claude/hooks/agent-vault-env".source = hook;
}
