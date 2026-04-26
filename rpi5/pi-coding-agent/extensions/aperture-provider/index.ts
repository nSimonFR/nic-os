// Registers an `aperture` provider so every pi request flows through the
// Tailscale Aperture AI gateway (https://ai.gate-mintaka.ts.net) → tiny-llm-gate
// (:4001) → codex-proxy (:4040) for ChatGPT subscription models, or beast
// Ollama for local models. tlg's openai handler routes by model id; see
// rpi5/tiny-llm-gate.nix for the routing table.
//
// This is a custom provider (registered via pi's extension API rather than
// models.json) because pi's `--provider` flag only accepts known names —
// see docs/custom-provider.md.
//
// Use via:
//   pi --provider aperture --model gpt-5.5         # ChatGPT subscription
//   pi --provider aperture --model gemma4:e4b      # Beast Ollama
//   pi --provider aperture --model auto            # Beast first, codex fallback
// (the `pi` / `pi-beast` / `pi-local` zsh aliases wrap these.)
//
// Costs are zeroed because the user pays via the ChatGPT/Codex subscription
// (gpt-5.x) or runs free locally on beast (gemma4/qwen3.6) — pi shouldn't
// estimate per-token billing for either.

const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

export default function (pi: any) {
  pi.registerProvider("aperture", {
    baseUrl: "https://ai.gate-mintaka.ts.net/v1",
    apiKey: "OPENAI_API_KEY",
    api: "openai-completions",
    models: [
      // -- ChatGPT subscription via codex-proxy --
      {
        id: "gpt-5.5",
        name: "GPT-5.5 (Codex subscription)",
        reasoning: false,
        input: ["text"],
        cost: ZERO_COST,
        contextWindow: 272000,
        maxTokens: 128000,
      },
      {
        id: "gpt-5.5-mini",
        name: "GPT-5.5 mini (Codex subscription)",
        reasoning: false,
        input: ["text"],
        cost: ZERO_COST,
        contextWindow: 272000,
        maxTokens: 128000,
      },
      {
        id: "gpt-5.2",
        name: "GPT-5.2 (Codex subscription)",
        reasoning: false,
        input: ["text"],
        cost: ZERO_COST,
        contextWindow: 400000,
        maxTokens: 128000,
      },
      {
        id: "gpt-5.3-codex",
        name: "GPT-5.3 codex (Codex subscription)",
        reasoning: false,
        input: ["text"],
        cost: ZERO_COST,
        contextWindow: 400000,
        maxTokens: 128000,
      },
      // -- Local Ollama on beast (RTX 3080 Ti) --
      {
        id: "gemma4:e4b",
        name: "Gemma 4 e4b (beast Ollama)",
        reasoning: false,
        input: ["text"],
        cost: ZERO_COST,
        contextWindow: 32768,
        maxTokens: 8192,
      },
      {
        id: "gemma4:26b",
        name: "Gemma 4 26b (beast Ollama)",
        reasoning: false,
        input: ["text"],
        cost: ZERO_COST,
        contextWindow: 32768,
        maxTokens: 8192,
      },
      {
        id: "qwen3.6:35b-a3b",
        name: "Qwen 3.6 35b-a3b (beast Ollama)",
        reasoning: false,
        input: ["text"],
        cost: ZERO_COST,
        contextWindow: 32768,
        maxTokens: 8192,
      },
      // -- Auto: beast-first with codex fallback --
      {
        id: "auto",
        name: "Auto (beast Ollama → codex gpt-5.5 fallback)",
        reasoning: false,
        input: ["text"],
        cost: ZERO_COST,
        contextWindow: 32768,
        maxTokens: 8192,
      },
    ],
  });
}
