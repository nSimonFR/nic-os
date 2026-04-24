# tiny-llm-gate — single Go binary replacing LiteLLM and affine-embed-proxy.
#
# Listens on :4001 (formerly LiteLLM), serves both OpenAI and Gemini
# protocols, and routes ChatGPT traffic through codex-proxy (:4040) for
# proper token counts and tool_calls support. Target RSS: < 15 MiB.
{ config, pkgs, lib, inputs, beastOllamaUrl, ... }:
let
  port = 4001;
  beastApi = "${beastOllamaUrl}/v1";
  affineWorkspaceId = "35d244cd-e6d5-4b3d-b1c2-fa50cab50621";
in
{
  imports = [ inputs.tiny-llm-gate.nixosModules.default ];

  services.tiny-llm-gate = {
    enable = true;
    package = inputs.tiny-llm-gate.packages.${pkgs.stdenv.hostPlatform.system}.default;

    memoryMax = "60M";
    goMemLimit = "40MiB";
    secretPaths = [ "/run/agenix/affine-token" "/run/agenix/claude-oauth" ];

    settings = {
      listen = "127.0.0.1:${toString port}";

      providers = {
        # Ollama on beast — no auth, plain OpenAI-compat.
        ollama = {
          type = "openai";
          base_url = beastApi;
          api_key = "ollama";
        };

        # Codex: codex-proxy (icebear0828/codex-proxy) translates
        # /v1/chat/completions → ChatGPT's /responses API with proper
        # token counts and tool_calls support.
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
        "qwen3.6:35b-a3b"    = { provider = "ollama"; upstream_model = "qwen3.6:35b-a3b"; };
        "qwen3-embedding:8b" = {
          provider = "ollama";
          upstream_model = "qwen3-embedding:8b";
          # AFFiNE's pgvector column is vector(1024). The @ai-sdk/google
          # SDK doesn't reliably forward outputDimensionality, so
          # tiny-llm-gate injects this default when the client omits it.
          default_embed_dimensions = 1024;
        };

        # -- Codex-proxy models (OpenAI subscription via OAuth) --
        "gpt-5.5" = {
          provider = "codex";
          upstream_model = "gpt-5.5";
          fallback = [ "gemma4:e4b" ];
        };
        "gpt-5.5-mini" = {
          provider = "codex";
          upstream_model = "gpt-5.5-mini";
          fallback = [ "gemma4:e4b" ];
        };
        "gpt-5.2"            = { provider = "codex"; upstream_model = "gpt-5.2"; };
        "gpt-5.3-codex"      = { provider = "codex"; upstream_model = "gpt-5.3-codex"; };
        "codex-auto-review"  = { provider = "codex"; upstream_model = "codex-auto-review"; };

        # "auto" — local-first model: try gemma4:e4b on beast, fall back to
        # codex gpt-5.5 if beast is unreachable (TCP refused / timeout) or
        # returns 5xx. Used by Sure (via OPENAI_MODEL) to prefer free local
        # inference when beast is awake while keeping the assistant working
        # when it's asleep. tiny-llm-gate's fallback chain triggers on both
        # transport errors and 5xx — see internal/server/openai.go.
        "auto" = {
          provider       = "ollama";
          upstream_model = "gemma4:e4b";
          fallback       = [ "gpt-5.5" ];
        };
      };

      aliases = {
        # PicoClaw strips "openai/" prefix, older configs may still carry
        # it — handle both.
        "openai/gemma4:e4b"          = "gemma4:e4b";
        "openai/gemma4:26b"          = "gemma4:26b";
        "openai/qwen3.6:35b-a3b"     = "qwen3.6:35b-a3b";
        "openai/qwen3-embedding:8b"  = "qwen3-embedding:8b";
        "openai/gpt-5.5"             = "gpt-5.5";
        "openai/gpt-5.5-mini"        = "gpt-5.5-mini";
        "openai/gpt-5.2"             = "gpt-5.2";
        "openai/gpt-5.3-codex"       = "gpt-5.3-codex";
        "openai/codex-auto-review"   = "codex-auto-review";

        # AFFiNE hardcodes OpenAI GPT model names for its OpenAI provider.
        # Route through "auto" so beast-down falls back to codex.
        "gpt-4.1-2025-04-14" = "auto";
        "gpt-4.1-mini"       = "auto";
        "gpt-4o"             = "auto";
        "gpt-4o-mini"        = "auto";

        # AFFiNE hardcodes OpenAI embedding model names.
        "text-embedding-3-small" = "qwen3-embedding:8b";
        "text-embedding-3-large" = "qwen3-embedding:8b";

        # AFFiNE Gemini provider model names (served by Gemini frontend).
        # Route through "auto" so beast-down falls back to codex.
        "gemini-2.5-flash"     = "auto";
        "gemini-2.5-pro"       = "auto";
        "gemini-2.0-flash"     = "auto";
        "gemini-2.0-flash-001" = "auto";
        "gemini-embedding-001" = "qwen3-embedding:8b";
        "text-embedding-004"   = "qwen3-embedding:8b";
      };

      # MCP transport bridges — replaces the 2-process supergateway chain
      # (~187 MB) with a native Go bridge (~1 MB overhead).
      mcp_bridges = {
        affine = {
          frontend = "sse";
          backend = "streamable_http";
          upstream_url = "http://127.0.0.1:13010/api/workspaces/${affineWorkspaceId}/mcp";
          path_prefix = "/mcp/affine";
          auth = {
            type = "bearer";
            token_file = "/run/agenix/affine-token";
          };
        };
      };

      # Anthropic passthrough proxy — Aperture sits in front (Claude Code's
      # ANTHROPIC_BASE_URL points at Aperture), and forwards /v1/messages
      # here with its own apikey. We strip that apikey and replace it with
      # the configured long-lived token from agenix, then forward to
      # api.anthropic.com. Aperture sees the full real request and response
      # bodies for observability (session tracking + content visibility).
      anthropic = {
        upstream = "https://api.anthropic.com";
        auth = {
          type = "bearer";
          token_file = "/run/agenix/claude-oauth";
        };
      };
    };
  };

  # Starts after codex-proxy and affine so upstreams are available.
  systemd.services.tiny-llm-gate = {
    after = [ "network.target" "openai-codex-proxy.service" "affine.service" ];
    wants = [ "openai-codex-proxy.service" ];
  };
}
