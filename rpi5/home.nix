{
  inputs,
  pkgs,
  username,
  ...
}:
{
  imports = [
    ./picoclaw/picoclaw.nix
    ./hermes/hermes.nix
    ./mail.nix
  ];

  home.packages = with pkgs; [
    nodejs_22
    pnpm
    vdirsyncer
    khal
    (callPackage ./gogcli.nix { gogcli-src = inputs.gogcli-src; })
    (callPackage ./goplaces.nix { goplaces-src = inputs.goplaces-src; })

    # Runtime toggle between the two "claw" agents. Both user services are
    # installed; only one may poll the shared Telegram bot at a time, so this
    # stops one and starts the other without a rebuild. The BOOT default is set
    # declaratively by `clawBackend` in flake.nix — this is the live override.
    (writeShellScriptBin "claw-switch" ''
      set -eu
      sc="${pkgs.systemd}/bin/systemctl --user"
      case "''${1:-status}" in
        picoclaw) on=picoclaw; off=hermes ;;
        hermes)   on=hermes;   off=picoclaw ;;
        status)
          $sc --no-pager -p ActiveState show picoclaw hermes \
            | ${pkgs.gnugrep}/bin/grep ActiveState || true
          exit 0 ;;
        *) echo "usage: claw-switch [picoclaw|hermes|status]" >&2; exit 2 ;;
      esac
      $sc stop "$off" 2>/dev/null || true
      $sc start "$on"
      echo "claw-switch: $on running, $off stopped (boot default still clawBackend in flake.nix)"
    '')
  ];

  home = {
    username = username;
    homeDirectory = "/home/${username}";

    # The codex CLI authenticates to the local codex-proxy (:4040) with this API
    # key (~/.codex/config.toml: env_key = "CODEX_PROXY_KEY") instead of a ChatGPT
    # login, so ~/.codex/auth.json holds no `tokens` block to rotate the proxy's
    # shared OAuth lineage out from under it (which used to silently 401 the proxy
    # and take picoclaw down). Non-secret: the loopback proxy accepts any inbound
    # key. ⚠️ Never run `codex login` — it re-adds tokens and restarts the war.
    # See known_issue_codex_proxy_oauth_rotation.
    sessionVariables.CODEX_PROXY_KEY = "codex-proxy-local";
  };

}
