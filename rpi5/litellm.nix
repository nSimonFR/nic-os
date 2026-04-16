{ pkgs, lib, ... }:
let
  litellmBin = "${pkgs.litellm}/bin/litellm";
  port = 4001;

  litellmConfig = pkgs.writeText "litellm-gateway-config.yaml" ''
    model_list:
      # -- Chat models (Ollama on beast) --
      - model_name: "openai/gemma4:e4b"
        litellm_params:
          model: openai/gemma4:e4b
          api_base: http://100.125.240.34:11434/v1
          api_key: ollama
          drop_params: true

      - model_name: "openai/gemma4:26b"
        litellm_params:
          model: openai/gemma4:26b
          api_base: http://100.125.240.34:11434/v1
          api_key: ollama
          drop_params: true

      - model_name: "openai/qwen3.5:35b-a3b"
        litellm_params:
          model: openai/qwen3.5:35b-a3b
          api_base: http://100.125.240.34:11434/v1
          api_key: ollama
          drop_params: true

      # -- Embedding model (Ollama on beast) --
      - model_name: "openai/qwen3-embedding:8b"
        litellm_params:
          model: openai/qwen3-embedding:8b
          api_base: http://100.125.240.34:11434/v1
          api_key: ollama
          drop_params: true

      # -- Codex-proxy models (chat fallback) --
      - model_name: "openai/gpt-5.4-mini"
        litellm_params:
          model: openai/gpt-5.4-mini
          api_base: http://127.0.0.1:4040/v1
          api_key: unused
          drop_params: true

    litellm_settings:
      drop_params: true
  '';

  # Wrapper: reads Phoenix JWT from agenix at runtime, sets OTEL env vars, execs litellm
  litellmWrapper = pkgs.writeShellScript "litellm-gateway" ''
    export OPENAI_API_KEY=ollama
    exec ${litellmBin} --config ${litellmConfig} --host 127.0.0.1 --port ${toString port}
  '';
in
{
  systemd.services.litellm-gateway = {
    description = "LiteLLM API gateway (Ollama + codex-proxy)";
    after = [ "network.target" "openai-codex-proxy.service" ];
    wants = [ "openai-codex-proxy.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = litellmWrapper;
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;
      MemoryMax = "300M";
    };
  };
}
