import json

from conftest import FakeOpener, json_reply
from nicos_scripts.connectors import journal_summary as js

MEMO = """☁️ Couvert · 9-21 °C

### 📷 Photos - 2

- [12:28](https://immich/photos/a) · Rome

### 💼 Travail - 1 réunion (15min) 3 personnes

<details>
<summary>Réunions</summary>

- **09:20-09:35** Secret meeting · 3 personnes

</details>

### 🕰 Souvenirs

- [Il y a 4 ans · 2022](https://immich/memories/x) · Bordeaux

### 🌳 Généalogie - 1 événement

- 🕯 Il y a 175 ans s'éteignait François

___________

#photos #work
"""


def test_visible_drops_links_collapsed_blocks_past_sections_and_tags():
    v = js.visible(MEMO)
    assert "12:28 · Rome" in v and "https://" not in v
    assert "Secret meeting" not in v and "Bordeaux" not in v and "François" not in v
    assert "#photos" not in v and "### 💼 Travail" in v


def test_visible_drops_the_open_in_dawarich_line():
    assert "Voir" not in js.visible("### 🚲 Vélo - 1 trajet\n\n- a\n\n[Voir la journée dans Dawarich](https://d)\n")


def test_a_new_prompt_means_a_new_sentence():
    before = js.source_hash(MEMO)
    js.PROMPT, saved = js.PROMPT + " ", js.PROMPT
    try:
        assert js.source_hash(MEMO) != before
    finally:
        js.PROMPT = saved


def test_summarize_sends_the_visible_text_and_cleans_the_answer():
    op = FakeOpener([json_reply({"choices": [{"message": {"content": " *« Une journée à Rome. »* \n"}}]})])
    assert js.summarize("http://gate", "gpt-6-luna", MEMO, op) == "Une journée à Rome."
    sent = json.loads(op.last.data)
    assert op.last.full_url == "http://gate/v1/chat/completions" and sent["model"] == "gpt-6-luna"
    assert "Secret meeting" not in sent["messages"][1]["content"]


def test_summarize_is_none_when_the_gate_is_down():
    def down(req, timeout=None):
        import urllib.error
        raise urllib.error.URLError("refused")
    assert js.summarize("http://gate", "m", MEMO, down) is None


def test_source_hash_ignores_collapsed_detail():
    assert js.source_hash(MEMO) == js.source_hash(MEMO.replace("Secret meeting", "Other"))
    assert js.source_hash(MEMO) != js.source_hash(MEMO.replace("Rome", "Paris"))
