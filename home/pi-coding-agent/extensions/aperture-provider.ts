// Registers an `aperture` provider routing all openai-completions traffic
// through the Tailscale Aperture observability gateway → tiny-llm-gate
// (:4001) → codex-proxy (:4040) or beast Ollama. Model id list is fetched
// from the gateway's /v1/models; per-model metadata (context window, max
// tokens, reasoning, modalities) is read from pi-ai's bundled MODELS table
// — same source of truth pi's built-in providers use, no duplication.
//
// pi rejects custom names on --provider; extensions are the only path.
//
// Costs are zeroed unconditionally: gpt-5.x is paid via the ChatGPT/Codex
// subscription (per-token pricing in pi-ai is wrong for that route),
// gemma4/qwen3.6 are free local on beast.

import { getModel } from "@mariozechner/pi-ai";

const BASE_URL = "https://ai.gate-mintaka.ts.net/v1";
const FETCH_TIMEOUT_MS = 2000;
const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

// tlg-internal aliases that point at specific Ollama tags on beast.
// Not in any public registry by design; conservative defaults are fine.
const OLLAMA_FALLBACK = { contextWindow: 32768, maxTokens: 8192 };

type Meta = { contextWindow: number; maxTokens: number; reasoning?: boolean; input?: string[] };

function lookupMeta(id: string): Meta {
  return getModel("openai-codex", id) ?? getModel("openai", id) ?? OLLAMA_FALLBACK;
}

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
    // /v1/models unreachable — register an empty list; user will see no
    // aperture models until the gate is back. Better than guessing.
    ids = [];
  }

  const models = ids.map((id) => {
    const meta = lookupMeta(id);
    return {
      id,
      name: id,
      reasoning: meta.reasoning ?? false,
      input: meta.input ?? ["text"],
      cost: ZERO_COST,
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
