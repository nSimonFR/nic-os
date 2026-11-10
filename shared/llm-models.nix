# Every model tiny-llm-gate serves, defined once. Everything else derives:
# the gate's `models`/`aliases`, Aperture's route list, and — for entries with
# `picker = true`, in this order — T3 Code's Codex harness (/codex/models),
# Hermes' /model.
#
# Entry: id, provider (a gate provider), upstream (default: id), fallback,
# picker, plus any other gate model field (e.g. default_embed_dimensions).
let
  models = [
    # ── Picker ──────────────────────────────────────────────────────────────
    # ChatGPT plan (codex). The codex surface wants the tier-suffixed upstream
    # id: a bare `gpt-6` is rejected for a ChatGPT account.
    {
      id = "gpt-6-luna";
      provider = "codex";
      fallback = [ "gemma4:e4b" ];
      picker = true;
    }
    {
      id = "gpt-6.1-sol";
      provider = "codex";
      fallback = [ "gemma4:e4b" ];
      picker = true;
    }
    {
      id = "gpt-6.1-terra";
      provider = "codex";
      picker = true;
    }
    # Astra burned the plan quota far faster than 5.6 (default rolled back
    # 2026-09-09): picker-only, never a standing default.
    {
      id = "gpt-6";
      provider = "codex";
      upstream = "gpt-6-astra";
      fallback = [ "gemma4:e4b" ];
      picker = true;
    }
    # Asale: paid in USDT, so never in an automatic fallback.
    {
      id = "asale-gpt-6-luna";
      provider = "asale";
      upstream = "gpt-6-luna";
      picker = true;
    }
    {
      id = "asale-gpt-6.1-sol";
      provider = "asale";
      upstream = "gpt-6.1-sol";
      picker = true;
    }
    {
      id = "asale-gpt-6-astra";
      provider = "asale";
      upstream = "gpt-6-astra";
      picker = true;
    }
    # Local: beast Ollama, then the Mac's oMLX (no fallback: a sleeping Mac
    # should error, not spend codex quota).
    {
      id = "gemma4:26b";
      provider = "ollama";
      picker = true;
    }
    {
      id = "qwen3.8:27b";
      provider = "ollama";
      picker = true;
    }
    {
      id = "Qwen3.6-27B-4bit";
      provider = "omlx";
      picker = true;
    }
    {
      id = "Qwen3.6-35B-A3B-4bit-DWQ";
      provider = "omlx";
      picker = true;
    }

    # ── Pinned by services, not offered ─────────────────────────────────────
    # pi, Wealthfolio and "auto"'s codex hop.
    {
      id = "gpt-5.6";
      provider = "codex";
      upstream = "gpt-5.6-sol";
      fallback = [ "gemma4:e4b" ];
    }
    # Four Hermes cron jobs (~/.hermes/cron/jobs.json).
    {
      id = "gpt-5.6-terra";
      provider = "codex";
      fallback = [ "gemma4:e4b" ];
    }
    # Karakeep, and the first hop of "auto".
    {
      id = "gemma4:e4b";
      provider = "ollama";
    }
    # Papra tagging. Beast-only, NO fallback: OCR'd bank/tax/ID text must never
    # reach a cloud model; a beast-down error makes the sweeper retry later.
    {
      id = "qwen3-vl:8b";
      provider = "ollama";
    }
    # AFFiNE embeddings: its pgvector column is vector(1024) and the client
    # doesn't reliably send the dimension.
    {
      id = "qwen3-embedding:8b";
      provider = "ollama";
      default_embed_dimensions = 1024;
    }
    # "auto"'s last resort, on the shared Anthropic OAuth pool.
    {
      id = "claude";
      provider = "claude";
      upstream = "claude-opus-5";
    }
    # Local-first with a resilience cascade: beast → codex → Claude. Fallback
    # fires on transport errors and 5xx.
    {
      id = "auto";
      provider = "ollama";
      upstream = "gemma4:e4b";
      fallback = [
        "gpt-5.6"
        "claude"
      ];
    }
  ];

  # Ids that clients hardcode → gate model.
  aliases = {
    # Sure, Alfie's Hermes "candidatures" profile (private repo) and Hermes
    # /model overrides persisted per chat. Same models, so Aperture's suffix
    # match can't misroute them the way `asale/gpt-6-luna` once did.
    "openai/gpt-6-luna" = "gpt-6-luna";
    "openai/gpt-6.1-sol" = "gpt-6.1-sol";
    "openai/gpt-6.1-terra" = "gpt-6.1-terra";
    # Wealthfolio's baked-in thread-title model; a title is cheap, keep it local.
    "gpt-5.4-nano" = "auto";
    # AFFiNE's hardcoded OpenAI and Gemini names.
    "gpt-4.1-2025-04-14" = "auto";
    "gpt-4.1-mini" = "auto";
    "gpt-4o" = "auto";
    "gpt-4o-mini" = "auto";
    "gemini-2.5-flash" = "auto";
    "gemini-2.5-pro" = "auto";
    "gemini-2.0-flash" = "auto";
    "gemini-2.0-flash-001" = "auto";
    "text-embedding-3-small" = "qwen3-embedding:8b";
    "text-embedding-3-large" = "qwen3-embedding:8b";
    "gemini-embedding-001" = "qwen3-embedding:8b";
    "text-embedding-004" = "qwen3-embedding:8b";
  };

  gateModel =
    m:
    removeAttrs m [
      "id"
      "upstream"
      "picker"
    ]
    // {
      upstream_model = m.upstream or m.id;
    };
in
{
  inherit models aliases;
  gate = builtins.listToAttrs (
    map (m: {
      name = m.id;
      value = gateModel m;
    }) models
  );
  picker = map (m: m.id) (builtins.filter (m: m.picker or false) models);
}
