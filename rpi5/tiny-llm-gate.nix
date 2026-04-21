# tiny-llm-gate — single Go binary replacing LiteLLM, openai-codex-proxy,
# and affine-embed-proxy.
#
# Listens on :4001 (formerly LiteLLM), serves both OpenAI and Gemini
# protocols, and authenticates directly against ChatGPT's Codex backend via
# OAuth — no separate codex-proxy hop. Target RSS: < 15 MiB.
{ pkgs, lib, inputs, beastOllamaUrl, ... }:
let
  port = 4001;
  beastApi = "${beastOllamaUrl}/v1";
in
{
  imports = [ inputs.tiny-llm-gate.nixosModules.default ];

  services.tiny-llm-gate = {
    enable = true;
    package = inputs.tiny-llm-gate.packages.${pkgs.stdenv.hostPlatform.system}.default;

    memoryMax = "50M";
    goMemLimit = "30MiB";

    settings = {
      listen = "127.0.0.1:${toString port}";

      providers = {
        # Ollama on beast — no auth, plain OpenAI-compat.
        ollama = {
          type = "openai";
          base_url = beastApi;
          api_key = "ollama";
        };

        # Codex: direct-to-ChatGPT OAuth was attempted and reverted — the
        # Codex backend's native API is `/responses`, not `/chat/completions`,
        # and translating between them requires porting the Vercel `ai` SDK
        # chat-to-responses transform. Until that lands in tiny-llm-gate, we
        # keep openai-codex-proxy (Node, ~60 MB) as the intermediary.
        codex = {
          type = "openai";
          base_url = "http://127.0.0.1:4040/v1";
          api_key = "unused";
        };
      };

      models = {
        # -- Ollama chat models --
        "gemma4:e4b"         = { provider = "ollama"; upstream_model = "gemma4:e4b"; };
        "gemma4:26b"         = { provider = "ollama"; upstream_model = "gemma4:26b"; };
        "qwen3.5:35b-a3b"    = { provider = "ollama"; upstream_model = "qwen3.5:35b-a3b"; };
        "qwen3-embedding:8b" = {
          provider = "ollama";
          upstream_model = "qwen3-embedding:8b";
          # AFFiNE's pgvector column is vector(1024). The @ai-sdk/google
          # SDK doesn't reliably forward outputDimensionality, so
          # tiny-llm-gate injects this default when the client omits it.
          default_embed_dimensions = 1024;
        };

        # -- Codex-proxy models (OpenAI subscription via OAuth) --
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
        "gpt-5.2"            = { provider = "codex"; upstream_model = "gpt-5.2"; };
        "gpt-5.3-codex"      = { provider = "codex"; upstream_model = "gpt-5.3-codex"; };
        "codex-auto-review"  = { provider = "codex"; upstream_model = "codex-auto-review"; };

        # "auto" — local-first model: try gemma4:e4b on beast, fall back to
        # codex gpt-5.4 if beast is unreachable (TCP refused / timeout) or
        # returns 5xx. Used by Sure (via OPENAI_MODEL) to prefer free local
        # inference when beast is awake while keeping the assistant working
        # when it's asleep. tiny-llm-gate's fallback chain triggers on both
        # transport errors and 5xx — see internal/server/openai.go.
        "auto" = {
          provider       = "ollama";
          upstream_model = "gemma4:e4b";
          fallback       = [ "gpt-5.4" ];
        };
      };

      aliases = {
        # PicoClaw strips "openai/" prefix, older configs may still carry
        # it — handle both.
        "openai/gemma4:e4b"          = "gemma4:e4b";
        "openai/gemma4:26b"          = "gemma4:26b";
        "openai/qwen3.5:35b-a3b"     = "qwen3.5:35b-a3b";
        "openai/qwen3-embedding:8b"  = "qwen3-embedding:8b";
        "openai/gpt-5.4"             = "gpt-5.4";
        "openai/gpt-5.4-mini"        = "gpt-5.4-mini";
        "openai/gpt-5.2"             = "gpt-5.2";
        "openai/gpt-5.3-codex"       = "gpt-5.3-codex";
        "openai/codex-auto-review"   = "codex-auto-review";

        # AFFiNE hardcodes OpenAI GPT model names for its OpenAI provider.
        "gpt-4.1-2025-04-14" = "gemma4:e4b";
        "gpt-4.1-mini"       = "gemma4:e4b";
        "gpt-4o"             = "gemma4:e4b";
        "gpt-4o-mini"        = "gemma4:e4b";

        # AFFiNE hardcodes OpenAI embedding model names.
        "text-embedding-3-small" = "qwen3-embedding:8b";
        "text-embedding-3-large" = "qwen3-embedding:8b";

        # AFFiNE Gemini provider model names (served by Gemini frontend).
        "gemini-2.5-flash"     = "gemma4:e4b";
        "gemini-2.5-pro"       = "gemma4:e4b";
        "gemini-2.0-flash"     = "gemma4:e4b";
        "gemini-2.0-flash-001" = "gemma4:e4b";
        "gemini-embedding-001" = "qwen3-embedding:8b";
        "text-embedding-004"   = "qwen3-embedding:8b";
      };
    };
  };

  # Starts after codex-proxy so upstream is available when first requests
  # land.
  systemd.services.tiny-llm-gate = {
    after = [ "network.target" "openai-codex-proxy.service" ];
    wants = [ "openai-codex-proxy.service" ];
  };
}
