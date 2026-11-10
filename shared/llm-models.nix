# Models tiny-llm-gate declares, and the picker. Everything else is discovered
# at runtime from each provider's model list (`discover` in
# hosts/rpi5/agents/tiny-llm-gate.nix), so a new upstream model needs no edit here.
#
# Declare a model only when something pins it, an alias targets it, or it needs
# a fallback, a rename or a field like default_embed_dimensions.
# Entry: id, provider, upstream (default: id), fallback, other gate model fields.
let
  models = [
    # ── Picker default and alias targets ────────────────────────────────────
    # Hermes' default; Sure, the journal and travel-cal pin it.
    {
      id = "gpt-6-luna";
      provider = "codex";
      fallback = [ "gemma4:e4b" ];
    }
    {
      id = "gpt-6.1-sol";
      provider = "codex";
      fallback = [ "gemma4:e4b" ];
    }
    {
      id = "gpt-6.1-terra";
      provider = "codex";
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
  # T3's Codex harness and Hermes' /model, in order: ids, `*` globs over
  # declared + discovered models, `@provider`, and `!glob` to drop matches.
  picker = [
    "gpt-6-luna"
    "gpt-*"
    "!gpt-5*"
    "asale-gpt-*"
    "@ollama"
    "@omlx"
    "!*embed*"
    "!auto"
    "!gemma4:e4b"
    "!qwen3-vl*"
  ];
}
