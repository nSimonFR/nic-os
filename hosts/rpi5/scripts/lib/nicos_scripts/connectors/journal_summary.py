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

PROMPT = """\
Tu écris la phrase d'accroche d'une entrée de journal personnel (celui de Nicolas, à Paris). Elle dit ce qui définit CETTE journée : ce qu'il voudra retrouver en la relisant dans un an.

Priorités, de la plus forte à la plus faible :
1. Ce qui sort de l'ordinaire : voyage, vol, nouveau lieu, sortie ou événement à l'agenda (théâtre, concert, fête, dîner), visite chez des proches.
2. Les moments marquants : un record 🏆, séance d'escalade (surtout un niveau franchi ⬆️ ou des flashs), longue sortie, anniversaire d'un proche.
3. Le reste, seulement si la journée n'a rien d'autre.

Ignore la routine, sauf si elle est vraiment hors norme : la météo (seulement si extrême : neige, canicule, tempête), la musique écoutée, les séries d'affilée 🔥, le nombre de pas, les trajets domicile-travail, les réunions de travail, l'électricité, les dépenses, les prélèvements et la paperasse.
Les lignes « Airbnb · Nom » sont des voyageurs qui louent son appartement : ne les mentionne jamais.
🏡 marque un lieu de vie : Alfie, c'est chez lui (y être n'est pas un événement) ; les autres 🏡 sont chez des proches.
L'entrée tutoie Nicolas (« ton grand-oncle ») ; toi, écris avec sa voix (« mon grand-oncle »).

Si rien ne ressort, quelques mots suffisent (« Journée de travail tranquille. », « Dimanche calme à la maison. ») ; n'écris jamais « rien de marquant » ni « sans événement ».
S'il y a plusieurs moments, garde l'ordre de la journée (les heures sont dans l'entrée).

Forme : une seule phrase en français, 20 mots au plus, de préférence nominale, comme une note de carnet (« Matinée à Lisbonne, puis dîner chez des amis. »). Énonce les faits sans inventer de ressenti ni d'action (pas de « j'ai appris », « j'ai fêté », « j'ai profité »). Pas de remplissage : ni météo, ni trajet, ni formule creuse (« sans autre événement », « journée bien remplie ») pour allonger. Aucun chiffre sauf s'il fait la journée, pas d'emoji, pas de guillemets.
"""
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
        if not skip and line.strip() and not line.startswith("Voir "):
            out.append(line)
    return "\n".join(out)


def source_hash(text):
    """Changes with the visible text or the prompt: either one means a new sentence."""
    return hashlib.sha256((PROMPT + visible(text)).encode()).hexdigest()[:16]


def summarize(gate, model, text, opener=None, timeout=120):
    """The sentence, or None when the gate or model is unavailable."""
    body = json.dumps({"model": model, "temperature": 0.2,
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
