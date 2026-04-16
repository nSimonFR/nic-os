// Thin proxy: translates Gemini embedContent/batchEmbedContents → LiteLLM /v1/embeddings.
// All other requests (generateContent, streamGenerateContent, models) pass through to LiteLLM
// which handles them natively via model_group_alias.
//
// Config via env: LITELLM_HOST, LITELLM_PORT, EMBED_MODEL, EMBED_DIMS, LISTEN_PORT
'use strict';
const http = require('http');

const LITELLM = {
  hostname: process.env.LITELLM_HOST || '127.0.0.1',
  port: parseInt(process.env.LITELLM_PORT || '4001'),
};
const EMBED_MODEL = process.env.EMBED_MODEL || 'openai/qwen3-embedding:8b';
const DIMS        = parseInt(process.env.EMBED_DIMS || '1024');
const PORT        = parseInt(process.env.LISTEN_PORT || '11435');

const GEMINI_SINGLE = /\/models\/[^/:]+:embedContent$/;
const GEMINI_BATCH  = /\/models\/[^/:]+:batchEmbedContents$/;

function httpPost(path, payload) {
  return new Promise((resolve, reject) => {
    const body = Buffer.from(JSON.stringify(payload));
    const req = http.request({
      ...LITELLM, path, method: 'POST', timeout: 30000,
      headers: { 'content-type': 'application/json', 'content-length': body.length },
    }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        try { resolve(JSON.parse(Buffer.concat(chunks).toString())); }
        catch (e) { reject(e); }
      });
    });
    req.on('timeout', () => req.destroy(Object.assign(new Error('timeout'), { code: 'ETIMEDOUT' })));
    req.on('error', reject);
    req.end(body);
  });
}

function passthrough(req, res, body) {
  const headers = { ...req.headers, host: `${LITELLM.hostname}:${LITELLM.port}`, 'content-length': body.length };
  const up = http.request({ ...LITELLM, path: req.url, method: req.method, headers }, upRes => {
    res.writeHead(upRes.statusCode, upRes.headers);
    upRes.pipe(res);
  });
  up.on('error', e => { res.writeHead(502); res.end(e.message); });
  up.end(body);
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', async () => {
    const raw = Buffer.concat(chunks);

    // Gemini single embed → LiteLLM /v1/embeddings
    if (req.method === 'POST' && GEMINI_SINGLE.test(req.url)) {
      try {
        const g = JSON.parse(raw.toString());
        const text = g?.content?.parts?.[0]?.text || '';
        const data = await httpPost('/v1/embeddings', { model: EMBED_MODEL, input: [text], dimensions: DIMS });
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ embedding: { values: data?.data?.[0]?.embedding || [] } }));
      } catch (e) { res.writeHead(500); res.end(e.message); }
      return;
    }

    // Gemini batch embed → LiteLLM /v1/embeddings
    if (req.method === 'POST' && GEMINI_BATCH.test(req.url)) {
      try {
        const g = JSON.parse(raw.toString());
        const texts = (g?.requests || []).map(r => r?.content?.parts?.[0]?.text || '');
        const data = await httpPost('/v1/embeddings', { model: EMBED_MODEL, input: texts, dimensions: DIMS });
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ embeddings: (data?.data || []).map(d => ({ values: d.embedding })) }));
      } catch (e) { res.writeHead(500); res.end(e.message); }
      return;
    }

    // Everything else → passthrough to LiteLLM (generateContent, streamGenerateContent, models)
    passthrough(req, res, raw);
  });
});

server.listen(PORT, '127.0.0.1', () => {
  process.stderr.write(`affine-embed-proxy on :${PORT} -> LiteLLM ${LITELLM.hostname}:${LITELLM.port}\n`);
});
