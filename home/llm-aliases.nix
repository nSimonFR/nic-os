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

  # Use openai/ prefix pointing at Ollama's /v1 endpoint — avoids litellm bugs
  # with both ollama/ ('str' has no .get) and ollama_chat/ (array content unmarshal).
  beastConfig = pkgs.writeText "litellm-beast-config.yaml" ''
    model_list:
      - model_name: "openai/gemma4:e4b"
        litellm_params:
          model: openai/gemma4:e4b
          api_base: http://beast:11434/v1
          api_key: ollama
          drop_params: true

    litellm_settings:
      success_callback: ["otel"]
  '';

  beastWrapper = mkLitellmWrapper { configFile = beastConfig; port = 4001; logSuffix = "beast"; };

  beastProxy = {
    # gemma4:e4b: best fit for RTX 3080 Ti 12GB (llmfit score 89.2, Perfect, 62.7 tok/s, 78.5% VRAM)
    description = "litellm Anthropic→Ollama proxy (Beast RTX 3080 Ti via Tailscale, port 4001)";
    args = [ "${beastWrapper}" ];
    logSuffix = "beast";
  };

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
    # gemma4-a4b: 26.5B MoE, 4B active (score 67.8, 3.1 tok/s, 80% mem)
    # gemma4-e4b: 8B dense (score 63.9, 10.3 tok/s, 25% mem)
    description = "litellm Anthropic→Ollama proxy (local models, port 4000)";
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
