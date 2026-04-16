{ config, pkgs, lib, ... }:
let
  litellmBin = "${pkgs.litellm}/bin/litellm";
  phoenixKeyPath = config.age.secrets.phoenix-api-key.path;

  # Wrapper: reads Phoenix JWT from agenix at runtime, sets OTEL env vars, execs litellm
  mkLitellmWrapper = { configFile, port, logSuffix }: pkgs.writeShellScript "litellm-${logSuffix}" ''
    PHOENIX_JWT=$(cat "${phoenixKeyPath}" 2>/dev/null || echo "")
    export OPENAI_API_KEY=ollama
    export OTEL_EXPORTER_OTLP_ENDPOINT="https://app.phoenix.arize.com/s/nsimon/v1/traces"
    export OTEL_EXPORTER_OTLP_HEADERS="authorization=Bearer $PHOENIX_JWT"
    exec ${litellmBin} --config ${configFile} --port ${toString port}
  '';

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

    litellm_settings:
      success_callback: ["otel"]
  '';

  localWrapper = mkLitellmWrapper { configFile = localConfig; port = 4000; logSuffix = "ollama"; };

  localProxy = {
    description = "litellm Anthropic->Ollama proxy (local models, port 4000)";
    args = [ "${localWrapper}" ];
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
