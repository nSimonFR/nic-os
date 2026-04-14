{ pkgs, lib, ... }:
let
  litellmBin = "${pkgs.litellm}/bin/litellm";

  # litellm proxy definitions: name → { args, port, description }
  proxies = {
    litellm-ollama = {
      description = "litellm Anthropic→Ollama proxy (local, port 4000)";
      args = [ litellmBin "--model" "ollama_chat/gemma4:26b" "--port" "4000" ];
      logSuffix = "ollama";
    };
    litellm-beast = {
      description = "litellm Anthropic→Ollama proxy (Beast RTX 3080 Ti via Tailscale, port 4001)";
      args = [ litellmBin "--model" "ollama_chat/gemma4:26b" "--port" "4001" "--api_base" "http://beast:11434" ];
      logSuffix = "beast";
    };
  };
in
{
  # macOS: launchd user agents
  launchd.agents = lib.mkIf pkgs.stdenv.isDarwin (
    lib.mapAttrs (name: p: {
      enable = true;
      config = {
        ProgramArguments = p.args;
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/tmp/litellm-${p.logSuffix}.log";
        StandardErrorPath = "/tmp/litellm-${p.logSuffix}.log";
      };
    }) proxies
  );

  # Linux: systemd user services
  systemd.user.services = lib.mkIf pkgs.stdenv.isLinux (
    lib.mapAttrs (name: p: {
      Unit.Description = p.description;
      Service = {
        ExecStart = lib.escapeShellArgs p.args;
        Restart = "always";
        RestartSec = "5s";
      };
      Install.WantedBy = [ "default.target" ];
    }) proxies
  );
}
