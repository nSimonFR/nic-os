{ pkgs, lib, ... }:
let
  litellmBin = "${pkgs.litellm}/bin/litellm";

  beastProxy = {
    description = "litellm Anthropic→Ollama proxy (Beast RTX 3080 Ti via Tailscale, port 4001)";
    args = [ litellmBin "--model" "ollama_chat/gemma4:26b" "--port" "4001" "--api_base" "http://beast:11434" ];
    logSuffix = "beast";
  };

  localProxy = {
    description = "litellm Anthropic→Ollama proxy (local gemma4:26b, port 4000)";
    args = [ litellmBin "--model" "ollama_chat/gemma4:26b" "--port" "4000" ];
    logSuffix = "ollama";
  };

  mkLaunchdAgent = p: {
    enable = true;
    config = {
      ProgramArguments = p.args;
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "/tmp/litellm-${p.logSuffix}.log";
      StandardErrorPath = "/tmp/litellm-${p.logSuffix}.log";
    };
  };

  mkSystemdService = p: {
    Unit.Description = p.description;
    Service = {
      ExecStart = lib.escapeShellArgs p.args;
      Restart = "always";
      RestartSec = "5s";
    };
    Install.WantedBy = [ "default.target" ];
  };
in
{
  # Beast proxy: all machines (Tailscale-accessible)
  launchd.agents.litellm-beast = lib.mkIf pkgs.stdenv.isDarwin (mkLaunchdAgent beastProxy);
  systemd.user.services.litellm-beast = lib.mkIf pkgs.stdenv.isLinux (mkSystemdService beastProxy);

  # Local proxy: macOS only (gemma4:26b runs on the M3 Pro)
  launchd.agents.litellm-ollama = lib.mkIf pkgs.stdenv.isDarwin (mkLaunchdAgent localProxy);
}
