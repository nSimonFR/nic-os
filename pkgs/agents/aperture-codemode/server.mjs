#!/usr/bin/env node
// Code Mode over Aperture's MCP gateway: two tools (search, execute) instead of ~400.
// Env: APERTURE_MCP_URL (required), CODEMODE_EXCLUDE (comma-separated tool names to hide).
import { registerHooks } from "node:module";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { runSandbox } from "./sandbox.mjs";

// @cloudflare/codemode's main entry imports `cloudflare:workers` for its Durable Object
// runtime, which we don't use; the type generator and normalizeCode are plain JS.
registerHooks({
  resolve: (specifier, context, next) =>
    specifier === "cloudflare:workers"
      ? {
          url: "data:text/javascript,export class DurableObject{};export class RpcTarget{};export class WorkerEntrypoint{}",
          shortCircuit: true,
        }
      : next(specifier, context),
});
const { generateTypesFromJsonSchema, normalizeCode, sanitizeToolName } = await import(
  "@cloudflare/codemode"
);

const MAX_CHARS = 24_000;
const TOOLS_TTL_MS = 10 * 60_000;

export class Upstream {
  constructor(url, exclude = []) {
    this.url = url;
    this.exclude = new Set(exclude);
    this.cache = null;
  }

  async client() {
    if (!this.connecting) {
      const client = new Client({ name: "aperture-codemode", version: "0.1.0" });
      this.connecting = client
        .connect(new StreamableHTTPClientTransport(new URL(this.url)))
        .then(() => client)
        .catch((e) => {
          this.connecting = null;
          throw e;
        });
    }
    return this.connecting;
  }

  /** @returns {Promise<Map<string, object>>} sanitized name → upstream tool */
  async tools() {
    if (this.cache && Date.now() - this.cache.at < TOOLS_TTL_MS) return this.cache.tools;
    const client = await this.client();
    const tools = new Map();
    let cursor;
    do {
      const page = await client.listTools(cursor ? { cursor } : undefined, { timeout: 120_000 });
      for (const t of page.tools) if (!this.exclude.has(t.name)) tools.set(sanitizeToolName(t.name), t);
      cursor = page.nextCursor;
    } while (cursor);
    this.cache = { at: Date.now(), tools };
    return tools;
  }

  async call(name, input) {
    const tool = (await this.tools()).get(name);
    if (!tool) throw new Error(`Unknown tool codemode.${name}; use search to find tool names`);
    const client = await this.client();
    const r = await client.callTool({ name: tool.name, arguments: input }, undefined, {
      timeout: 120_000,
    });
    const text = (r.content ?? [])
      .filter((c) => c.type === "text")
      .map((c) => c.text)
      .join("\n");
    if (r.isError) throw new Error(text || `${tool.name} failed`);
    if (r.structuredContent != null) return r.structuredContent;
    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  }
}

const connectorOf = (name) => name.split("_")[0];

export function connectors(tools) {
  const counts = new Map();
  for (const t of tools.values()) counts.set(connectorOf(t.name), (counts.get(connectorOf(t.name)) ?? 0) + 1);
  return [...counts].map(([c, n]) => `${c} (${n})`).join(", ");
}

/** Keyword search over tool names and descriptions; returns TypeScript declarations. */
export function search(tools, query, limit = 10) {
  const terms = query.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  if (terms.length === 0) return `No query. Connectors: ${connectors(tools)}`;
  const scored = [];
  for (const [key, t] of tools) {
    const name = key.toLowerCase();
    const desc = (t.description ?? "").toLowerCase();
    let score = 0;
    for (const term of terms) {
      if (connectorOf(name) === term) score += 4;
      else if (name.includes(term)) score += 3;
      if (desc.includes(term)) score += 1;
    }
    if (score > 0) scored.push([score, key, t]);
  }
  scored.sort((a, b) => b[0] - a[0] || a[1].localeCompare(b[1]));
  const hits = scored.slice(0, limit);
  if (hits.length === 0) return `No tool matches "${query}". Connectors: ${connectors(tools)}`;
  const types = generateTypesFromJsonSchema(
    Object.fromEntries(
      hits.map(([, key, t]) => [key, { description: t.description, inputSchema: t.inputSchema }]),
    ),
  );
  const more = scored.length > hits.length ? `\n// ${scored.length - hits.length} more matches; refine the query.` : "";
  return types + more;
}

const truncate = (s) =>
  s.length > MAX_CHARS ? `${s.slice(0, MAX_CHARS)}\n… truncated (${s.length} chars): return less.` : s;

const text = (s, isError = false) => ({ content: [{ type: "text", text: truncate(s) }], isError });

export async function buildServer(upstream) {
  let known = "";
  try {
    known = ` Connectors: ${connectors(await upstream.tools())}.`;
  } catch (e) {
    console.error(`aperture-codemode: tool listing failed at start: ${e.message}`);
  }

  const server = new McpServer({ name: "aperture-codemode", version: "0.1.0" });
  server.registerTool(
    "search",
    {
      description:
        "Find tools of Nico's self-hosted services (mail, calendar, finance, photos, notes, home…) " +
        "and get their TypeScript declarations for use in `execute`. Query with keywords, e.g. " +
        `"sure transactions" or "immich search".${known}`,
      inputSchema: {
        query: z.string().describe("Keywords; a connector name lists its tools first"),
        limit: z.number().int().min(1).max(30).optional().describe("Max tools returned (default 10)"),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ query, limit }) => {
      try {
        return text(search(await upstream.tools(), query, limit ?? 10));
      } catch (e) {
        return text(`search failed: ${e.message}`, true);
      }
    },
  );

  server.registerTool(
    "execute",
    {
      description:
        "Run JavaScript calling the tools found with `search`, chaining and filtering results " +
        "in code so only what matters comes back. Write an async arrow function that returns " +
        "the result: `async () => { const a = await codemode.sure_get_accounts({}); return a; }`. " +
        "Each `codemode.<tool>(input)` returns parsed JSON (or text) and throws on tool errors. " +
        "QuickJS sandbox: no fetch, fs, require or timers; console.log output is returned. 120 s limit.",
      inputSchema: { code: z.string().describe("An async arrow function") },
    },
    async ({ code }) => {
      const run = await runSandbox(normalizeCode(code), (name, input) => upstream.call(name, input));
      const logs = run.logs.length ? `\n\nconsole:\n${run.logs.join("\n")}` : "";
      if (run.error) return text(`Error: ${run.error}${logs}`, true);
      return text(JSON.stringify(run.result, null, 2) + logs);
    },
  );
  return server;
}

if (import.meta.main) {
  const url = process.env.APERTURE_MCP_URL;
  if (!url) {
    console.error("aperture-codemode: APERTURE_MCP_URL is required");
    process.exit(2);
  }
  const exclude = (process.env.CODEMODE_EXCLUDE ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const server = await buildServer(new Upstream(url, exclude));
  await server.connect(new StdioServerTransport());
}
