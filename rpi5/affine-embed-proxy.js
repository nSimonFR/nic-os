// AFFiNE AI proxy: translates Gemini API → Ollama (with codex-proxy failover)
//
// - Embeddings: embedContent/batchEmbedContents → Ollama /v1/embeddings
// - Chat: generateContent/streamGenerateContent → Ollama /v1/chat/completions
//   Falls back to codex-proxy (localhost:4040) if Ollama is unreachable.
//
// Config via env: OLLAMA_HOST, OLLAMA_PORT, FALLBACK_HOST, FALLBACK_PORT,
//                 CHAT_MODEL, FALLBACK_MODEL, EMBED_MODEL, EMBED_DIMS, LISTEN_PORT
'use strict';
const http = require('http');

const OLLAMA = {
  hostname: process.env.OLLAMA_HOST || '127.0.0.1',
  port: parseInt(process.env.OLLAMA_PORT || '4001'),
};
const FALLBACK = {
  hostname: process.env.FALLBACK_HOST || '127.0.0.1',
  port: parseInt(process.env.FALLBACK_PORT || '4040'),
};
const CHAT_MODEL     = process.env.CHAT_MODEL || 'openai/gemma4:e4b';
const FALLBACK_MODEL = process.env.FALLBACK_MODEL || 'openai/gpt-5.4-mini';
const EMBED_MODEL    = process.env.EMBED_MODEL || 'openai/qwen3-embedding:8b';
const DIMS           = parseInt(process.env.EMBED_DIMS || '1024');
const PORT           = parseInt(process.env.LISTEN_PORT || '11435');

const GEMINI_SINGLE = /\/models\/[^/:]+:embedContent$/;
const GEMINI_BATCH  = /\/models\/[^/:]+:batchEmbedContents$/;
const GEMINI_GEN    = /\/models\/[^/:]+:generateContent$/;
const GEMINI_STREAM = /\/models\/[^/:]+:streamGenerateContent/;
const RETRIABLE     = new Set(['ECONNREFUSED', 'EHOSTUNREACH', 'ETIMEDOUT', 'ECONNRESET']);

// ── HTTP helpers ────────────────────────────────────────────────────────

function httpPost(host, path, payload, timeout = 30000) {
  return new Promise((resolve, reject) => {
    const body = Buffer.from(JSON.stringify(payload));
    const req = http.request({
      ...host, path, method: 'POST', timeout,
      headers: { 'content-type': 'application/json', 'content-length': body.length },
    }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        try { resolve(JSON.parse(Buffer.concat(chunks).toString())); }
        catch(e) { reject(e); }
      });
    });
    req.on('timeout', () => req.destroy(Object.assign(new Error('timeout'), { code: 'ETIMEDOUT' })));
    req.on('error', reject);
    req.end(body);
  });
}

function httpStream(host, path, payload) {
  return new Promise((resolve, reject) => {
    const body = Buffer.from(JSON.stringify(payload));
    const req = http.request({
      ...host, path, method: 'POST', timeout: 30000,
      headers: { 'content-type': 'application/json', 'content-length': body.length },
    }, resolve);
    req.on('timeout', () => req.destroy(Object.assign(new Error('timeout'), { code: 'ETIMEDOUT' })));
    req.on('error', reject);
    req.end(body);
  });
}

// ── Gemini ↔ OpenAI format conversion ───────────────────────────────────

function geminiToOpenAI(g, model) {
  const messages = [];
  const sys = g.systemInstruction?.parts?.map(p => p.text).join('\n');
  if (sys) messages.push({ role: 'system', content: sys });
  for (const c of (g.contents || [])) {
    messages.push({
      role: c.role === 'model' ? 'assistant' : 'user',
      content: (c.parts || []).map(p => p.text || '').join(''),
    });
  }
  const cfg = g.generationConfig || {};
  return {
    model, messages,
    ...(cfg.temperature != null && { temperature: cfg.temperature }),
    ...(cfg.maxOutputTokens && { max_tokens: cfg.maxOutputTokens }),
    ...(cfg.topP != null && { top_p: cfg.topP }),
    ...(cfg.stopSequences?.length && { stop: cfg.stopSequences }),
  };
}

function openAIToGemini(data) {
  const text = data?.choices?.[0]?.message?.content || '';
  return {
    candidates: [{ content: { role: 'model', parts: [{ text }] }, finishReason: 'STOP' }],
    usageMetadata: {
      promptTokenCount: data?.usage?.prompt_tokens || 0,
      candidatesTokenCount: data?.usage?.completion_tokens || 0,
      totalTokenCount: data?.usage?.total_tokens || 0,
    },
  };
}

function openAIChunkToGemini(o) {
  const text = o.choices?.[0]?.delta?.content || '';
  const finish = o.choices?.[0]?.finish_reason;
  const gem = { candidates: [{ content: { role: 'model', parts: [{ text }] } }] };
  if (finish === 'stop') {
    gem.candidates[0].finishReason = 'STOP';
    gem.usageMetadata = {
      promptTokenCount: o.usage?.prompt_tokens || 0,
      candidatesTokenCount: o.usage?.completion_tokens || 0,
      totalTokenCount: o.usage?.total_tokens || 0,
    };
  }
  return gem;
}

// ── Chat with failover ──────────────────────────────────────────────────

async function chatNonStreaming(g, res) {
  let data;
  try {
    data = await httpPost(OLLAMA, '/v1/chat/completions', geminiToOpenAI(g, CHAT_MODEL), 30000);
  } catch (e) {
    if (!RETRIABLE.has(e.code)) { res.writeHead(502); res.end(e.message); return; }
    process.stderr.write(`Ollama unreachable (${e.code}), falling back to codex-proxy\n`);
    try {
      data = await httpPost(FALLBACK, '/v1/chat/completions', geminiToOpenAI(g, FALLBACK_MODEL));
    } catch (e2) { res.writeHead(502); res.end(e2.message); return; }
  }
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify(openAIToGemini(data)));
}

async function chatStreaming(g, res) {
  const payload = { ...geminiToOpenAI(g, CHAT_MODEL), stream: true };
  let upRes;
  try {
    upRes = await httpStream(OLLAMA, '/v1/chat/completions', payload);
  } catch (e) {
    if (!RETRIABLE.has(e.code)) { res.writeHead(502); res.end(e.message); return; }
    process.stderr.write(`Ollama unreachable (${e.code}), falling back to codex-proxy\n`);
    try {
      const fb = { ...geminiToOpenAI(g, FALLBACK_MODEL), stream: true };
      upRes = await httpStream(FALLBACK, '/v1/chat/completions', fb);
    } catch (e2) { res.writeHead(502); res.end(e2.message); return; }
  }

  if (upRes.statusCode !== 200) {
    const chunks = [];
    upRes.on('data', c => chunks.push(c));
    upRes.on('end', () => { res.writeHead(upRes.statusCode); res.end(Buffer.concat(chunks)); });
    return;
  }

  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  let buf = '';
  upRes.on('data', chunk => {
    buf += chunk.toString();
    const lines = buf.split('\n');
    buf = lines.pop();
    for (const line of lines) {
      if (!line.startsWith('data: ')) continue;
      const data = line.slice(6).trim();
      if (data === '[DONE]') {
        res.write('data: ' + JSON.stringify({
          candidates: [{ content: { role: 'model', parts: [{ text: '' }] }, finishReason: 'STOP' }],
          usageMetadata: { promptTokenCount: 0, candidatesTokenCount: 0, totalTokenCount: 0 },
        }) + '\n\n');
        res.end();
        return;
      }
      try {
        res.write('data: ' + JSON.stringify(openAIChunkToGemini(JSON.parse(data))) + '\n\n');
      } catch (_) {}
    }
  });
  upRes.on('end', () => { if (!res.writableEnded) res.end(); });
}

// ── Server ──────────────────────────────────────────────────────────────

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', async () => {
    const raw = Buffer.concat(chunks);

    // Gemini model list — populates the AFFiNE UI model dropdown
    if (/\/models(\?|$)/.test(req.url) && (req.method === 'GET' || req.method === 'POST')) {
      // Fetch Ollama models via GET /api/tags
      const models = await new Promise(resolve => {
        http.get({ ...OLLAMA, path: '/api/tags', timeout: 3000 }, upRes => {
          const c = []; upRes.on('data', d => c.push(d));
          upRes.on('end', () => { try { resolve(JSON.parse(Buffer.concat(c).toString())); } catch(_) { resolve(null); } });
        }).on('error', () => resolve(null)).on('timeout', function() { this.destroy(); resolve(null); });
      });
      const names = (models?.models || [])
        .filter(m => !m.name.includes('embedding'))
        .map(m => ({ name: 'models/' + m.name }));
      // Always include hardcoded model names AFFiNE expects
      const seen = new Set(names.map(n => n.name));
      for (const id of ['gemini-2.5-flash', 'gemini-2.0-flash-001', 'gemini-embedding-001']) {
        if (!seen.has('models/' + id)) names.push({ name: 'models/' + id });
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ models: names }));
      return;
    }

    // Gemini single embed
    if (req.method === 'POST' && GEMINI_SINGLE.test(req.url)) {
      try {
        const g = JSON.parse(raw.toString());
        const text = g?.content?.parts?.[0]?.text || '';
        const data = await httpPost(OLLAMA, '/v1/embeddings', { model: EMBED_MODEL, input: [text], dimensions: DIMS });
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ embedding: { values: data?.data?.[0]?.embedding || [] } }));
      } catch(e) { res.writeHead(500); res.end(e.message); }
      return;
    }

    // Gemini batch embed
    if (req.method === 'POST' && GEMINI_BATCH.test(req.url)) {
      try {
        const g = JSON.parse(raw.toString());
        const texts = (g?.requests || []).map(r => r?.content?.parts?.[0]?.text || '');
        const data = await httpPost(OLLAMA, '/v1/embeddings', { model: EMBED_MODEL, input: texts, dimensions: DIMS });
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ embeddings: (data?.data || []).map(d => ({ values: d.embedding })) }));
      } catch(e) { res.writeHead(500); res.end(e.message); }
      return;
    }

    // Gemini streaming chat
    if (req.method === 'POST' && GEMINI_STREAM.test(req.url)) {
      try { await chatStreaming(JSON.parse(raw.toString()), res); }
      catch(e) { if (!res.headersSent) { res.writeHead(500); res.end(e.message); } }
      return;
    }

    // Gemini non-streaming chat
    if (req.method === 'POST' && GEMINI_GEN.test(req.url)) {
      try { await chatNonStreaming(JSON.parse(raw.toString()), res); }
      catch(e) { res.writeHead(500); res.end(e.message); }
      return;
    }

    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: 'Unknown endpoint', code: 404 } }));
  });
});

server.listen(PORT, '127.0.0.1', () => {
  process.stderr.write(`affine-ai-proxy on :${PORT} -> ${OLLAMA.hostname}:${OLLAMA.port} (fallback: ${FALLBACK.hostname}:${FALLBACK.port})\n`);
});
