{ config, pkgs, lib, ... }:
let
  litellmBin = "${pkgs.litellm}/bin/litellm";

  # Config-file approach: one proxy, two models, aliases pick via ANTHROPIC_MODEL
  localConfig = pkgs.writeText "litellm-local-config.yaml" ''
    model_list:
      - model_name: gemma4-a4b
        litellm_params:
          model: openai/gemma4:26b-a4b-it-q4_K_M
          api_base: http://localhost:11434/v1
          api_key: ollama
          drop_params: true
      - model_name: gemma4-e4b
        litellm_params:
          model: openai/gemma4:e4b
          api_base: http://localhost:11434/v1
          api_key: ollama
          drop_params: true
  '';

  localProxy = {
    description = "litellm Anthropic->Ollama proxy (local models, port 4000)";
    args = [ "${litellmBin}" "--config" "${localConfig}" "--port" "4000" ];
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
in
{
  # Local proxy: macOS only (gemma4 models on the M3 Pro)
  launchd.agents.litellm-ollama = lib.mkIf pkgs.stdenv.isDarwin (mkLaunchdAgent localProxy);
}
