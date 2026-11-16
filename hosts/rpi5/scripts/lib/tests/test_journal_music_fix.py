"""journal-music-fix: swap the music section of memos that print "Artiste inconnu"."""

import json
import urllib.error

from conftest import FakeOpener, json_reply

from nicos_scripts.connectors import journal_daily as jd
from nicos_scripts.connectors import journal_music_fix as fix

OLD = "### 🎵 Musique - 2 titres · 7 min\n\n- **Artiste inconnu** · Club, Trop beau"
NEW = ("2 titres · 7 min", ["- **Lomepal** · Club, Trop beau"])
BODY = f"### 🚶 Activité - 3 pas\n\n{OLD}\n\n### 💸 Dépenses - 1 €\n\n___________\n\n#music\n"


def test_find_section_stops_at_the_next_heading_or_the_rule():
    assert fix.find_section(BODY) == OLD
    assert fix.find_section(f"{OLD}\n\n___________\n\n#music\n") == OLD
    assert fix.find_section("### 🚶 Activité") is None


def setup(tmp_path, monkeypatch, memo_content, text=f"*Résumé.*\n\n{BODY}"):
    state = tmp_path / "days.json"
    state.write_text(
        json.dumps(
            {
                "2026-11-09": {"memo": "memos/1", "text": text},
                "2026-11-10": {
                    "memo": "memos/2",
                    "text": "### 🎵 Musique - 1 titre\n\n- **A** · x",
                },
                "_work_dispatch": {"2026-11-09": "x"},
            }
        )
    )
    token = tmp_path / "token"
    token.write_text("tok")
    monkeypatch.setattr(jd, "day_music", lambda cfg, run, day, log: NEW)
    env = {
        "JOURNAL_STATE": str(state),
        "MEMOS_URL": "http://memos",
        "MEMOS_TOKEN_FILE": str(token),
    }
    op = FakeOpener([json_reply({"content": memo_content}), json_reply({})])
    return state, env, op


def test_dry_run_reports_and_writes_nothing(tmp_path, monkeypatch):
    state, env, op = setup(tmp_path, monkeypatch, f"*Résumé.*\n\n{BODY}")
    lines = []
    assert fix.main([], env=env, opener=op, log=lines.append) == 0
    assert op.requests == []
    assert "2026-11-09: 1 unknown artist line(s) -> 0" in lines[0]
    assert lines[-1] == "dry run: 1 memos would change"
    assert "Artiste inconnu" in json.loads(state.read_text())["2026-11-09"]["text"]


def test_apply_swaps_only_the_music_section_in_the_memo_and_the_state(
    tmp_path, monkeypatch
):
    current = f"*Résumé.*\n\n{BODY}\nmon ajout\n"
    state, env, op = setup(tmp_path, monkeypatch, current)
    assert fix.main(["--apply"], env=env, opener=op, log=lambda _l: None) == 0
    get, patch = op.requests
    assert get.get_method() == "GET" and get.full_url.endswith("/api/v1/memos/1")
    assert patch.get_method() == "PATCH"
    assert patch.full_url.endswith("/memos/1?updateMask=content")
    assert json.loads(patch.data) == {
        "content": current.replace(OLD, fix.music_section(NEW))
    }
    saved = json.loads(state.read_text())["2026-11-09"]["text"]
    assert "**Lomepal**" in saved and "Artiste inconnu" not in saved


def test_a_section_edited_by_hand_is_left_alone(tmp_path, monkeypatch):
    state, env, op = setup(tmp_path, monkeypatch, "*Résumé.*\n\nautre chose\n")
    lines = []
    assert fix.main(["--apply"], env=env, opener=op, log=lines.append) == 0
    assert [r.get_method() for r in op.requests] == ["GET"]
    assert any("edited by hand" in l for l in lines)
    assert "Artiste inconnu" in json.loads(state.read_text())["2026-11-09"]["text"]


def test_a_missing_memo_is_skipped(tmp_path, monkeypatch):
    state, env, _ = setup(tmp_path, monkeypatch, "")

    def gone():
        raise urllib.error.HTTPError("u", 404, "nf", {}, None)

    lines = []
    assert (
        fix.main(["--apply"], env=env, opener=FakeOpener([gone]), log=lines.append) == 0
    )
    assert any("not updated (404)" in l for l in lines)


def test_dates_on_the_command_line_restrict_the_days(tmp_path, monkeypatch):
    _, env, op = setup(tmp_path, monkeypatch, "")
    lines = []
    assert (
        fix.main(["--apply", "2026-01-01"], env=env, opener=op, log=lines.append) == 0
    )
    assert op.requests == [] and lines == ["done: 0 rewritten, 0 left alone"]


def test_without_a_state_path_it_refuses():
    lines = []
    assert fix.main([], env={}, log=lines.append) == 1
