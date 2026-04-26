// Registers an `aperture` provider routing all openai-completions traffic
// through the Tailscale Aperture observability gateway → tiny-llm-gate
// (:4001) → codex-proxy (:4040) or beast Ollama. tlg's openai handler
// routes by model id; see rpi5/tiny-llm-gate.nix for the routing table.
//
// Custom providers must come from a TS extension (pi's models.json only
// overrides known names; --provider rejects custom ones — see
// docs/custom-provider.md).
//
// Costs are zeroed: gpt-5.x is paid via the ChatGPT/Codex subscription,
// gemma4/qwen3.6 are free local on beast.

const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

export default function (pi: any) {
  pi.registerProvider("aperture", {
    baseUrl: "https://ai.gate-mintaka.ts.net/v1",
    apiKey: "OPENAI_API_KEY",
    api: "openai-completions",
    // Distinguish pi from Claude Code in Aperture's /api/sessions list
    // (the underlying OpenAI/JS SDK otherwise sends just "OpenAI/JS X.Y.Z").
    headers: {
      "User-Agent": "pi-coding-agent (nic-os)",
    },
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
      // gpt-5.5-mini intentionally absent: tlg routes it but codex-proxy
      // upstream returns "Model not found".
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
      // Beast-first with codex fallback (tlg-side; see auto in tiny-llm-gate.nix).
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
