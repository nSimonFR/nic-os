"""mitmproxy addon: log ChatGPT native-app conversations to JSONL.

POC (see plan cozy-wibbling-dijkstra): piggybacks on the existing Sumeria
transparent proxy. Hooks `response` for POST https://chatgpt.com/backend-api/
conversation, reconstructs {prompt, answer, model} from the request body + the
SSE response, and appends one JSON record per exchange to CHATGPT_LOG_FILE.

Design rules for the POC:
- Never break the flow. The whole hook is wrapped in try/except — a parse error
  must not stop the app from working, nor disturb the co-resident Sumeria addon.
- Never lose data. The raw (decoded) SSE body is always stored, so a wrong parse
  is still recoverable offline. Parsing is best-effort on top of that.
- Handle BOTH SSE shapes: the legacy full-message form (each event carries the
  whole message with progressively longer content.parts) and the newer "v1"
  delta-encoding form (JSON-pointer add/append/replace/patch ops).
"""

import datetime
import json
import os

from mitmproxy import ctx, http

LOG_FILE = os.environ["CHATGPT_LOG_FILE"]
RAW_CAP = 1_000_000  # bytes of raw SSE kept per record (POC safety cap)


# ── tiny JSON-pointer helpers (dict keys + int list indices, auto-vivifying) ──
def _tokens(path):
    # RFC6901-ish; we only ever see simple /a/b/0 paths from ChatGPT.
    if not path or path == "/":
        return []
    return [t.replace("~1", "/").replace("~0", "~") for t in path.lstrip("/").split("/")]


def _descend(root, tokens, create):
    cur = root
    for i, tok in enumerate(tokens[:-1]):
        nxt_is_index = tokens[i + 1].isdigit()
        if isinstance(cur, list):
            idx = int(tok)
            while create and idx >= len(cur):
                cur.append({} if not nxt_is_index else [])
            cur = cur[idx]
        else:
            if create and tok not in cur:
                cur[tok] = [] if nxt_is_index else {}
            cur = cur[tok]
    return cur


def _ptr_set(root, path, value):
    tokens = _tokens(path)
    if not tokens:
        return value  # replacing the root
    parent = _descend(root, tokens, create=True)
    last = tokens[-1]
    if isinstance(parent, list):
        idx = int(last)
        while idx >= len(parent):
            parent.append(None)
        parent[idx] = value
    else:
        parent[last] = value
    return root


def _ptr_get(root, path):
    cur = root
    for tok in _tokens(path):
        cur = cur[int(tok)] if isinstance(cur, list) else cur[tok]
    return cur


def _ptr_append(root, path, delta):
    try:
        cur = _ptr_get(root, path)
    except (KeyError, IndexError, TypeError):
        cur = ""
    if not isinstance(cur, str):
        cur = "" if cur is None else str(cur)
    return _ptr_set(root, path, cur + str(delta))


# ── SSE parsing ───────────────────────────────────────────────────────────────
def _iter_events(sse_text):
    """Yield parsed JSON objects from `data:` lines; skip [DONE] and non-JSON."""
    saw_v1 = False
    for line in sse_text.splitlines():
        line = line.strip()
        if line.startswith("event:") and "delta_encoding" in line:
            saw_v1 = True
            continue
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            yield json.loads(payload)
        except json.JSONDecodeError:
            continue
    return saw_v1


def _parse_full(events):
    """Legacy form: take the longest content.parts[0] seen across snapshots."""
    answer, model, conv = "", None, None
    for obj in events:
        msg = obj.get("message") if isinstance(obj, dict) else None
        conv = obj.get("conversation_id") or conv if isinstance(obj, dict) else conv
        if not isinstance(msg, dict):
            continue
        if (msg.get("author") or {}).get("role") not in (None, "assistant"):
            continue
        model = (msg.get("metadata") or {}).get("model_slug") or model
        parts = (msg.get("content") or {}).get("parts") or []
        if parts and isinstance(parts[0], str) and len(parts[0]) > len(answer):
            answer = parts[0]
    return answer, model, conv


def _apply_op(root, op, last_path):
    """Apply one delta op; return (root, new_last_path)."""
    if not isinstance(op, dict):
        return root, last_path
    o = op.get("o")
    p = op.get("p", last_path if o is None else "")
    v = op.get("v")
    if o == "patch" and isinstance(v, list):
        for sub in v:
            root, last_path = _apply_op(root, sub, last_path)
        return root, last_path
    if o in ("add", "replace"):
        root = _ptr_set(root, p, v)
    elif o == "append" or (o is None and isinstance(v, str)):
        root = _ptr_append(root, p, v)
    else:  # unknown op with a structured value → set it
        if p:
            root = _ptr_set(root, p, v)
    return root, (p or last_path)


def _parse_v1(events):
    """Delta-encoding form: replay JSON-pointer ops onto a reconstructed state."""
    root, last_path = {}, ""
    for obj in events:
        if isinstance(obj, dict) and obj.get("type"):
            continue  # control frames (message_stream_complete, etc.)
        root, last_path = _apply_op(root, obj, last_path)
    try:
        msg = root.get("message", {})
        answer = ((msg.get("content") or {}).get("parts") or [""])[0]
        model = (msg.get("metadata") or {}).get("model_slug")
        conv = root.get("conversation_id")
        return (answer if isinstance(answer, str) else ""), model, conv
    except (AttributeError, KeyError, IndexError, TypeError):
        return "", None, None


def _extract_prompt(req_body):
    """Pull the user's prompt(s) from the request JSON body."""
    try:
        data = json.loads(req_body)
    except (json.JSONDecodeError, TypeError):
        return None, None
    prompts = []
    for m in data.get("messages", []) or []:
        if (m.get("author") or {}).get("role") != "user":
            continue
        for part in (m.get("content") or {}).get("parts", []) or []:
            if isinstance(part, str) and part:
                prompts.append(part)
    return ("\n".join(prompts) or None), data.get("model")


class ChatGPTConversationLogger:
    def response(self, flow: http.HTTPFlow):
        try:
            self._handle(flow)
        except Exception as e:  # never let the app break on our account
            ctx.log.warn(f"[chatgpt-mitm] logger error (ignored): {e!r}")

    def _handle(self, flow: http.HTTPFlow):
        host = flow.request.pretty_host  # transparent mode: .host is the IP
        if "chatgpt.com" not in host:
            return
        if flow.request.method != "POST":
            return
        if flow.request.path.split("?", 1)[0].rstrip("/") != "/backend-api/conversation":
            return

        sse = flow.response.get_text(strict=False) or ""
        ctype = flow.response.headers.get("content-type", "")
        if "event-stream" not in ctype and "data:" not in sse[:64]:
            return  # not the streaming answer we're after

        ctx.log.info(f"[chatgpt-mitm] intercepted {host}{flow.request.path}")

        events = list(_iter_events(sse))
        a_v1, m_v1, c_v1 = _parse_v1(events)
        a_full, m_full, c_full = _parse_full(events)
        # Prefer whichever reconstruction actually produced text.
        answer = a_v1 or a_full
        model = m_v1 or m_full
        conversation_id = c_v1 or c_full

        prompt, req_model = _extract_prompt(flow.request.get_text(strict=False) or "")

        record = {
            "ts": datetime.datetime.now().isoformat(timespec="seconds"),
            "conversation_id": conversation_id,
            "model": model or req_model,
            "prompt": prompt,
            "answer": answer or None,
            "parsed_ok": bool(answer),
            "raw_sse": sse[:RAW_CAP],
            "raw_truncated": len(sse) > RAW_CAP,
        }
        with open(LOG_FILE, "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        ctx.log.info(
            f"[chatgpt-mitm] logged exchange parsed_ok={record['parsed_ok']} "
            f"model={record['model']} answer_len={len(answer or '')}"
        )


addons = [ChatGPTConversationLogger()]
