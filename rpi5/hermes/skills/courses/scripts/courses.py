#!/usr/bin/env python3
"""Read and update the shared "Liste de courses" (shopping list) in AFFiNE.

The list is the doc titled "Courses" inside the **Burgie Land** workspace. We
talk to it through the local affine-mcp server (DAWNCR0W) that already runs on
127.0.0.1:7021 and is wired into picoclaw — no AFFiNE token plumbing needed
here, only the MCP bearer (a world-readable 0444 agenix file).

Subcommands:
    show                 Print the list (default if no args).
    add <item ...>       Add an item (unchecked). Joins all following words.
    done <text ...>      Tick the first un-ticked item matching <text>.
    undone <text ...>    Un-tick the first ticked item matching <text>.
    remove <text ...>    Delete the first item matching <text>.
    clear-done           Delete every ticked (bought) item.

Matching is case-insensitive substring. Output is plain text on stdout for
picoclaw to relay; the script never messages Telegram itself.

No external dependencies (stdlib urllib only).

Env overrides (all optional):
    AFFINE_MCP_URL          default http://127.0.0.1:7021/mcp
    AFFINE_MCP_HTTP_TOKEN   bearer token (else read from token file)
    AFFINE_MCP_TOKEN_FILE   default /run/agenix/affine-mcp-http-token
    COURSES_WORKSPACE_ID    default Burgie Land workspace id
    COURSES_DOC_ID          default "Courses" doc id
"""
import json
import os
import sys
import urllib.request

MCP_URL = os.environ.get("AFFINE_MCP_URL", "http://127.0.0.1:7021/mcp")
TOKEN_FILE = os.environ.get("AFFINE_MCP_TOKEN_FILE", "/run/agenix/affine-mcp-http-token")
# Burgie Land workspace + its "Courses" doc. IDs are stable; the doc can also be
# re-found by title with the affine-mcp `get_doc_by_title` tool if it ever moves.
WORKSPACE_ID = os.environ.get("COURSES_WORKSPACE_ID", "0b8e6d06-c5e9-475f-a772-7c467e0c247e")
DOC_ID = os.environ.get("COURSES_DOC_ID", "_ssS4PUSXQoAU8P8xL32q")


def _token():
    tok = os.environ.get("AFFINE_MCP_HTTP_TOKEN")
    if tok:
        return tok.strip()
    with open(TOKEN_FILE, encoding="utf-8") as fh:
        return fh.read().strip()


class MCP:
    """Minimal MCP streamable-HTTP client (initialize -> notify -> tools/call)."""

    def __init__(self):
        self._token = _token()
        self._sid = None
        self._post({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "courses-skill", "version": "1"},
            },
        })
        # The server assigns the session id on the initialize response; the
        # "initialized" notification (and every later call) must echo it back.
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _post(self, payload):
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Content-Type": "application/json",
            # The server replies with text/event-stream; both must be accepted.
            "Accept": "application/json, text/event-stream",
        }
        if self._sid:
            headers["Mcp-Session-Id"] = self._sid
        req = urllib.request.Request(
            MCP_URL, data=json.dumps(payload).encode("utf-8"),
            headers=headers, method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            if self._sid is None:
                self._sid = resp.headers.get("mcp-session-id")
            return self._parse(resp.read().decode("utf-8"))

    @staticmethod
    def _parse(body):
        # SSE framing: one or more "data: {json}" lines. Tolerate raw JSON and
        # empty bodies (notification acks return 202 with no content).
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("data:"):
                return json.loads(line[5:].strip())
        body = body.strip()
        return json.loads(body) if body else {}

    def call(self, name, arguments):
        resp = self._post({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        })
        if "error" in resp:
            raise RuntimeError(resp["error"].get("message", str(resp["error"])))
        text = resp["result"]["content"][0]["text"]
        try:
            return json.loads(text)
        except (ValueError, TypeError):
            return text


def load(mcp):
    """Return the list as [{checked: bool|None, text: str}] in document order.

    checked is None for any non-todo line (preserved verbatim on save).
    """
    doc = mcp.call("read_doc", {
        "workspaceId": WORKSPACE_ID, "docId": DOC_ID, "includeMarkdown": True,
    })
    md = doc.get("markdown", "") if isinstance(doc, dict) else ""
    items = []
    for raw in md.splitlines():
        stripped = raw.strip()
        low = stripped.lower()
        if low.startswith("- [x]"):
            items.append({"checked": True, "text": stripped[5:].strip()})
        elif low.startswith("- [ ]"):
            items.append({"checked": False, "text": stripped[5:].strip()})
        elif stripped:
            items.append({"checked": None, "text": raw})
    return items


def render(items):
    lines = []
    for it in items:
        if it["checked"] is None:
            lines.append(it["text"])
        else:
            box = "x" if it["checked"] else " "
            lines.append(f"- [{box}] {it['text']}")
    return "\n".join(lines)


def save(mcp, items):
    md = render(items).strip()
    # replace_doc_with_markdown requires non-empty content; keep one blank todo
    # so an emptied list stays a valid, editable checklist.
    mcp.call("replace_doc_with_markdown", {
        "workspaceId": WORKSPACE_ID, "docId": DOC_ID,
        "markdown": md if md else "- [ ] ",
    })


def show(items):
    todo = [it for it in items if it["checked"] is False and it["text"]]
    done = [it for it in items if it["checked"] is True and it["text"]]
    out = ["🛒 Liste de courses (Burgie Land)", ""]
    out.append("À acheter :")
    if todo:
        out += [f"• {it['text']}" for it in todo]
    else:
        out.append("• (rien — liste à jour ✅)")
    if done:
        out += ["", "Déjà pris :"]
        out += [f"• {it['text']}" for it in done]
    print("\n".join(out))


def _find(items, needle, want_checked):
    needle = needle.lower()
    for it in items:
        if it["checked"] is want_checked and needle in it["text"].lower():
            return it
    return None


def main(argv):
    cmd = argv[0] if argv else "show"
    rest = " ".join(argv[1:]).strip()
    mcp = MCP()

    if cmd == "show":
        show(load(mcp))
        return 0

    if cmd == "add":
        if not rest:
            print("usage: add <item>")
            return 2
        mcp.call("append_markdown", {
            "workspaceId": WORKSPACE_ID, "docId": DOC_ID,
            "markdown": f"- [ ] {rest}",
        })
        print(f"✅ Ajouté : {rest}")
        show(load(mcp))
        return 0

    if cmd in ("done", "undone", "remove"):
        if not rest:
            print(f"usage: {cmd} <text>")
            return 2
        items = load(mcp)
        if cmd == "remove":
            hit = _find(items, rest, False) or _find(items, rest, True)
            if not hit:
                print(f"❓ Introuvable : {rest}")
                return 1
            items.remove(hit)
            save(mcp, items)
            print(f"🗑️ Retiré : {hit['text']}")
        elif cmd == "done":
            hit = _find(items, rest, False)
            if not hit:
                print(f"❓ Aucun article à acheter ne correspond à : {rest}")
                return 1
            hit["checked"] = True
            save(mcp, items)
            print(f"✅ Pris : {hit['text']}")
        else:  # undone
            hit = _find(items, rest, True)
            if not hit:
                print(f"❓ Aucun article déjà pris ne correspond à : {rest}")
                return 1
            hit["checked"] = False
            save(mcp, items)
            print(f"↩️ Remis à acheter : {hit['text']}")
        show(load(mcp))
        return 0

    if cmd == "clear-done":
        items = load(mcp)
        kept = [it for it in items if it["checked"] is not True]
        removed = len(items) - len(kept)
        save(mcp, kept)
        print(f"🧹 {removed} article(s) déjà pris supprimé(s).")
        show(load(mcp))
        return 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
