// Registers an `aperture` provider routing all openai-completions traffic
// through the Tailscale Aperture observability gateway → tiny-llm-gate
// (:4001) → codex-proxy (:4040) or beast Ollama. Model list is fetched
// from the gateway's /v1/models so new tlg routes show up automatically;
// per-model context/maxTokens come from MODEL_META below.
//
// pi rejects custom names on --provider; extensions are the only path.
//
// Costs are zeroed: gpt-5.x is paid via the ChatGPT/Codex subscription,
// gemma4/qwen3.6 are free local on beast.

const BASE_URL = "https://ai.gate-mintaka.ts.net/v1";
const FETCH_TIMEOUT_MS = 2000;

type Meta = { name: string; contextWindow: number; maxTokens: number };

// Known ids → display name + window. Unknown ids fall through with defaults.
const MODEL_META: Record<string, Meta> = {
  "gpt-5.5":      { name: "GPT-5.5 (Codex subscription)",       contextWindow: 272000, maxTokens: 128000 },
  "gpt-5.2":      { name: "GPT-5.2 (Codex subscription)",       contextWindow: 400000, maxTokens: 128000 },
  "gpt-5.3-codex":{ name: "GPT-5.3 codex (Codex subscription)", contextWindow: 400000, maxTokens: 128000 },
  "gemma4:e4b":   { name: "Gemma 4 e4b (beast Ollama)",         contextWindow:  32768, maxTokens:   8192 },
  "gemma4:26b":   { name: "Gemma 4 26b (beast Ollama)",         contextWindow:  32768, maxTokens:   8192 },
  "qwen3.6:35b-a3b": { name: "Qwen 3.6 35b-a3b (beast Ollama)", contextWindow:  32768, maxTokens:   8192 },
  "auto":         { name: "Auto (beast → codex fallback)",      contextWindow:  32768, maxTokens:   8192 },
};
const DEFAULTS: Meta = { name: "", contextWindow: 32768, maxTokens: 8192 };

// Filter out embeddings, openai/* aliases, and Anthropic passthrough
// (handled via pi's models.json baseUrl override, not this provider).
function isChatModel(id: string): boolean {
  if (id.includes("embedding")) return false;
  if (id.startsWith("openai/")) return false;
  if (id.startsWith("claude-")) return false;
  if (id === "codex-auto-review") return false;
  return true;
}

async function fetchModelIds(): Promise<string[]> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await fetch(`${BASE_URL}/models`, { signal: ctrl.signal });
    const body = (await res.json()) as { data?: { id: string }[] };
    return (body.data ?? []).map((m) => m.id).filter(isChatModel);
  } finally {
    clearTimeout(timer);
  }
}

export default async function (pi: any) {
  let ids: string[];
  try {
    ids = await fetchModelIds();
  } catch {
    ids = Object.keys(MODEL_META);
  }

  const models = ids.map((id) => {
    const meta = MODEL_META[id] ?? DEFAULTS;
    return {
      id,
      name: meta.name || id,
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: meta.contextWindow,
      maxTokens: meta.maxTokens,
    };
  });

  pi.registerProvider("aperture", {
    baseUrl: BASE_URL,
    apiKey: "OPENAI_API_KEY",
    api: "openai-completions",
    // Distinguishes pi from Claude Code in Aperture's /api/sessions list.
    headers: { "User-Agent": "pi-coding-agent (nic-os)" },
    models,
  });
}
