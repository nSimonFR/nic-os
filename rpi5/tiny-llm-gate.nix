# tiny-llm-gate — memory-conscious replacement for LiteLLM.
#
# Phase: parallel deploy. Runs on port 4002 alongside LiteLLM on 4001 so the
# two can be diff-tested against real client traffic. No client is rewired
# yet — everything still hits LiteLLM. Once we've verified parity, a follow-up
# PR will swap clients to :4002 and remove litellm.nix.
{ pkgs, lib, inputs, beastOllamaUrl, ... }:
let
  port = 4002;
  beastApi = "${beastOllamaUrl}/v1";
  codexApi = "http://127.0.0.1:4040/v1";
in
{
  imports = [ inputs.tiny-llm-gate.nixosModules.default ];

  services.tiny-llm-gate = {
    enable = true;
    package = inputs.tiny-llm-gate.packages.${pkgs.stdenv.hostPlatform.system}.default;

    # Parallel-deploy ceilings. Production settings once we cut over.
    memoryMax = "40M";
    goMemLimit = "25MiB";

    settings = {
      listen = "127.0.0.1:${toString port}";

      providers = {
        ollama = {
          type = "openai";
          base_url = beastApi;
          api_key = "ollama";
        };
        codex = {
          type = "openai";
          base_url = codexApi;
          api_key = "unused";
        };
      };

      models = {
        # -- Ollama chat models --
        "gemma4:e4b"        = { provider = "ollama"; upstream_model = "gemma4:e4b"; };
        "gemma4:26b"        = { provider = "ollama"; upstream_model = "gemma4:26b"; };
        "qwen3.5:35b-a3b"   = { provider = "ollama"; upstream_model = "qwen3.5:35b-a3b"; };
        "qwen3-embedding:8b" = { provider = "ollama"; upstream_model = "qwen3-embedding:8b"; };

        # -- Codex-proxy models (OpenAI subscription via OAuth) --
        # Fallbacks only on gpt-5.4 / gpt-5.4-mini to match LiteLLM's behaviour.
        "gpt-5.4" = {
          provider = "codex";
          upstream_model = "gpt-5.4";
          fallback = [ "gemma4:e4b" ];
        };
        "gpt-5.4-mini" = {
          provider = "codex";
          upstream_model = "gpt-5.4-mini";
          fallback = [ "gemma4:e4b" ];
        };
        "gpt-5.2"             = { provider = "codex"; upstream_model = "gpt-5.2"; };
        "gpt-5.3-codex"       = { provider = "codex"; upstream_model = "gpt-5.3-codex"; };
        "codex-auto-review"   = { provider = "codex"; upstream_model = "codex-auto-review"; };
      };

      # All client-facing aliases. Note: LiteLLM splits these across
      # `model_list` (name → real model) and `router_settings.model_group_alias`;
      # tiny-llm-gate collapses them into one flat table.
      aliases = {
        # PicoClaw strips "openai/" prefix, but some older configs may still
        # carry it — handle both.
        "openai/gemma4:e4b"        = "gemma4:e4b";
        "openai/gemma4:26b"        = "gemma4:26b";
        "openai/qwen3.5:35b-a3b"   = "qwen3.5:35b-a3b";
        "openai/qwen3-embedding:8b" = "qwen3-embedding:8b";
        "openai/gpt-5.4"           = "gpt-5.4";
        "openai/gpt-5.4-mini"      = "gpt-5.4-mini";
        "openai/gpt-5.2"           = "gpt-5.2";
        "openai/gpt-5.3-codex"     = "gpt-5.3-codex";
        "openai/codex-auto-review" = "codex-auto-review";

        # AFFiNE hardcodes OpenAI GPT model names for its OpenAI provider.
        "gpt-4.1-2025-04-14" = "gemma4:e4b";
        "gpt-4.1-mini"       = "gemma4:e4b";
        "gpt-4o"             = "gemma4:e4b";
        "gpt-4o-mini"        = "gemma4:e4b";

        # AFFiNE hardcodes OpenAI embedding model names.
        "text-embedding-3-small" = "qwen3-embedding:8b";
        "text-embedding-3-large" = "qwen3-embedding:8b";

        # AFFiNE Gemini provider model names. Phase 4 will move these under a
        # dedicated Gemini frontend; for now they're routed through the OpenAI
        # frontend (clients that send Gemini-native /v1beta/… payloads still
        # go through LiteLLM on :4001).
        "gemini-2.5-flash"     = "gemma4:e4b";
        "gemini-2.5-pro"       = "gemma4:e4b";
        "gemini-2.0-flash"     = "gemma4:e4b";
        "gemini-2.0-flash-001" = "gemma4:e4b";
        "gemini-embedding-001" = "qwen3-embedding:8b";
        "text-embedding-004"   = "qwen3-embedding:8b";
      };
    };
  };

  # Ordering: depends on codex-proxy for its upstream, same as LiteLLM.
  systemd.services.tiny-llm-gate = {
    after = [ "network.target" "openai-codex-proxy.service" ];
    wants = [ "openai-codex-proxy.service" ];
  };
}
