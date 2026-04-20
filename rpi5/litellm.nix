{ pkgs, lib, beastOllamaUrl, ... }:
let
  litellmBin = "${pkgs.litellm}/bin/litellm";
  port = 4001;
  beastApi = "${beastOllamaUrl}/v1";

  litellmConfig = pkgs.writeText "litellm-gateway-config.yaml" ''
    model_list:
      # -- Chat models (Ollama on beast) --
      - model_name: "openai/gemma4:e4b"
        litellm_params:
          model: openai/gemma4:e4b
          api_base: ${beastApi}
          api_key: ollama
          drop_params: true

      - model_name: "openai/gemma4:26b"
        litellm_params:
          model: openai/gemma4:26b
          api_base: ${beastApi}
          api_key: ollama
          drop_params: true

      - model_name: "openai/qwen3.5:35b-a3b"
        litellm_params:
          model: openai/qwen3.5:35b-a3b
          api_base: ${beastApi}
          api_key: ollama
          drop_params: true

      # -- Embedding model (Ollama on beast) --
      - model_name: "openai/qwen3-embedding:8b"
        litellm_params:
          model: openai/qwen3-embedding:8b
          api_base: ${beastApi}
          api_key: ollama
          drop_params: true

      # -- Embedding aliases (AFFiNE OpenAI provider requests these) --
      - model_name: "text-embedding-3-small"
        litellm_params:
          model: openai/qwen3-embedding:8b
          api_base: ${beastApi}
          api_key: ollama
          drop_params: true

      - model_name: "text-embedding-3-large"
        litellm_params:
          model: openai/qwen3-embedding:8b
          api_base: ${beastApi}
          api_key: ollama
          drop_params: true

      # -- Chat aliases (AFFiNE hardcodes various GPT model names) --
      - model_name: "gpt-4.1-2025-04-14"
        litellm_params:
          model: openai/gemma4:e4b
          api_base: ${beastApi}
          api_key: ollama
          drop_params: true

      - model_name: "gpt-4.1-mini"
        litellm_params:
          model: openai/gemma4:e4b
          api_base: ${beastApi}
          api_key: ollama
          drop_params: true

      - model_name: "gpt-4o"
        litellm_params:
          model: openai/gemma4:e4b
          api_base: ${beastApi}
          api_key: ollama
          drop_params: true

      - model_name: "gpt-4o-mini"
        litellm_params:
          model: openai/gemma4:e4b
          api_base: ${beastApi}
          api_key: ollama
          drop_params: true

      # -- Codex-proxy models (OpenAI subscription via oauth proxy) --
      - model_name: "openai/gpt-5.4-mini"
        litellm_params:
          model: openai/gpt-5.4-mini
          api_base: http://127.0.0.1:4040/v1
          api_key: unused
          drop_params: true

      - model_name: "openai/gpt-5.4"
        litellm_params:
          model: openai/gpt-5.4
          api_base: http://127.0.0.1:4040/v1
          api_key: unused
          drop_params: true

      - model_name: "openai/gpt-5.2"
        litellm_params:
          model: openai/gpt-5.2
          api_base: http://127.0.0.1:4040/v1
          api_key: unused
          drop_params: true

      - model_name: "openai/gpt-5.3-codex"
        litellm_params:
          model: openai/gpt-5.3-codex
          api_base: http://127.0.0.1:4040/v1
          api_key: unused
          drop_params: true

      - model_name: "openai/codex-auto-review"
        litellm_params:
          model: openai/codex-auto-review
          api_base: http://127.0.0.1:4040/v1
          api_key: unused
          drop_params: true

    litellm_settings:
      drop_params: true
      # Fallback chain for PicoClaw's `primary` model. If Codex proxy (gpt-5.4)
      # fails or times out, LiteLLM transparently retries against the local
      # Ollama model on beast. Keeps the Telegram bot responsive when OpenAI
      # is unreachable.
      fallbacks:
        - "openai/gpt-5.4": ["openai/gemma4:e4b"]
        - "openai/gpt-5.4-mini": ["openai/gemma4:e4b"]

    # Gemini model name → LiteLLM model group mapping.
    # AFFiNE's Gemini provider sends /v1beta/models/MODEL:generateContent;
    # LiteLLM's native router translates and routes via these aliases.
    router_settings:
      model_group_alias:
        "gemini-2.5-flash": "openai/gemma4:e4b"
        "gemini-2.5-pro": "openai/gemma4:e4b"
        "gemini-2.0-flash": "openai/gemma4:e4b"
        "gemini-2.0-flash-001": "openai/gemma4:e4b"
        "gemini-embedding-001": "openai/qwen3-embedding:8b"
        "text-embedding-004": "openai/qwen3-embedding:8b"
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
