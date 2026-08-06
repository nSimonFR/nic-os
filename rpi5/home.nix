{
  inputs,
  pkgs,
  username,
  ...
}:
{
  imports = [
    ./hermes/hermes.nix
    ./mail.nix
  ];

  home.packages = with pkgs; [
    nodejs_22
    pnpm
    (callPackage ../pkgs/cli/gogcli.nix { gogcli-src = inputs.gogcli-src; })
    (callPackage ../pkgs/cli/goplaces.nix { goplaces-src = inputs.goplaces-src; })
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
