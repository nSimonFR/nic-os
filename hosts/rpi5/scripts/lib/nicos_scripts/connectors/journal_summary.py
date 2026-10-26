"""
One-sentence summary on top of a journal-daily memo, through tiny-llm-gate.

The model sees only the memo's visible text: links, collapsed <details>
blocks (meeting titles, project notes, family history) and the past-facing
sections are stripped first, since the default model runs in the cloud.
"""

import hashlib
import json
import re
import socket
import urllib.error
import urllib.request

PROMPT = (
    "Tu résumes la journée d'un journal personnel en UNE seule phrase en français, "
    "25 mots au plus, au présent, ton sobre et chaleureux. N'utilise que les faits "
    "fournis, n'invente rien, pas d'emoji, pas de chiffres secondaires, pas de "
    "guillemets. Commence directement par le contenu (pas de « Aujourd'hui »)."
)
SKIP = ("### 🕰", "### 🌳")  # the past, not the day


def visible(text):
    """The memo as the model should see it: no links, no collapsed blocks, no
    tags, no past-facing sections."""
    text = re.sub(r"<details>.*?</details>", "", text, flags=re.S)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    out, skip = [], False
    for line in text.splitlines():
        if line.startswith("### "):
            skip = line.startswith(SKIP)
        if line.startswith("_____"):
            break
        if not skip and line.strip():
            out.append(line)
    return "\n".join(out)


def source_hash(text):
    return hashlib.sha256(visible(text).encode()).hexdigest()[:16]


def summarize(gate, model, text, opener=None, timeout=120):
    """The sentence, or None when the gate or model is unavailable."""
    body = json.dumps({"model": model, "temperature": 0.3,
                       "messages": [{"role": "system", "content": PROMPT},
                                    {"role": "user", "content": visible(text)}]}).encode()
    req = urllib.request.Request(f"{gate}/v1/chat/completions", data=body, method="POST",
                                 headers={"Authorization": "Bearer ollama", "Content-Type": "application/json"})
    try:
        with (opener or urllib.request.urlopen)(req, timeout=timeout) as r:
            content = json.load(r)["choices"][0]["message"]["content"]
    except (urllib.error.URLError, TimeoutError, socket.timeout, KeyError, IndexError, ValueError):
        return None
    line = " ".join(content.split()).strip().strip("*_\"«» ")
    return line or None
