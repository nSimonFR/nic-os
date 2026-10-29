"""hermes-burgie-photo: album scoping, origin chat, and the Agent Vault route."""

import json
import urllib.error

import pytest

from conftest import FakeResponse, json_reply
from nicos_scripts.hermes import burgie_photo as bp

ALBUM = {"id": "a1", "albumName": "🧸 Burgiiiiiiie [AUTO]", "assetCount": 2}
ASSETS = {"assets": {"total": 2, "items": [
    {"id": "img", "type": "IMAGE"}, {"id": "vid", "type": "VIDEO"}]}}


def _home(tmp_path, chat="-100"):
    (tmp_path / "cron").mkdir()
    jobs = {"jobs": [{"id": "5eb0b7dd6e7f", "origin": {"chat_id": chat}}]}
    (tmp_path / "cron" / "jobs.json").write_text(json.dumps(jobs))
    return bp.Config.from_env({"HERMES_HOME": str(tmp_path)})


def _replies(sent_chat="-100"):
    return [
        json_reply([ALBUM, {"id": "a2", "albumName": "Holidays"}]),
        json_reply(ASSETS),
        lambda: FakeResponse(b"\xff\xd8jpeg"),
        json_reply({"ok": True, "result": {"chat": {"id": int(sent_chat)}}}),
    ]


def test_defaults_route_immich_through_agent_vault():
    cfg = bp.Config.from_env({})
    assert cfg.immich_url == "http://immich.home.arpa:2283"
    assert cfg.api_key == "__immich_api_key__"


def test_run_sends_an_image_from_the_album_to_the_origin_chat(tmp_path, opener):
    cfg = _home(tmp_path)
    fake = opener(_replies())
    bp.run(cfg, opener=fake, choice=lambda xs: xs[0], token="T")

    urls = [r.full_url for r in fake.requests]
    assert urls[0].startswith("http://immich.home.arpa:2283/api/albums")
    assert fake.body_of(1)["albumIds"] == ["a1"]
    assert urls[2].endswith("/api/assets/img/thumbnail?size=preview")
    assert all(r.get_header("X-api-key") == "__immich_api_key__" for r in fake.requests[:3])
    assert urls[3] == "https://api.telegram.org/botT/sendPhoto"
    assert b'name="chat_id"\r\n\r\n-100\r\n' in fake.requests[3].data
    assert b"\xff\xd8jpeg" in fake.requests[3].data


def test_only_images_are_candidates(tmp_path, opener):
    seen = []
    bp.run(_home(tmp_path), opener=opener(_replies()),
           choice=lambda xs: seen.extend(xs) or xs[0], token="T")
    assert [a["id"] for a in seen] == ["img"]


def _raise(exc):
    def reply():
        raise exc
    return reply


def test_immich_timeout_is_retried_then_sends_once(tmp_path, opener):
    sleeps = []
    fake = opener([_raise(TimeoutError("timed out")), *_replies()])
    bp.run(_home(tmp_path), opener=fake, choice=lambda xs: xs[0], token="T",
           sleep=sleeps.append)
    assert sleeps == [bp.IMMICH_RETRY_SECONDS]
    assert sum(r.full_url.endswith("/sendPhoto") for r in fake.requests) == 1


def test_immich_gives_up_after_the_last_attempt(tmp_path, opener):
    sleeps = []
    fake = opener([_raise(urllib.error.URLError("refused"))])
    with pytest.raises(urllib.error.URLError):
        bp.run(_home(tmp_path), opener=fake, token="T", sleep=sleeps.append)
    assert len(fake.requests) == bp.IMMICH_ATTEMPTS
    assert len(sleeps) == bp.IMMICH_ATTEMPTS - 1


def test_immich_http_error_is_not_retried(tmp_path, opener):
    err = urllib.error.HTTPError("u", 401, "Unauthorized", {}, None)
    fake = opener([_raise(err)])
    with pytest.raises(urllib.error.HTTPError):
        bp.run(_home(tmp_path), opener=fake, token="T", sleep=pytest.fail)
    assert len(fake.requests) == 1


def test_telegram_delivered_elsewhere_is_a_failure(tmp_path, opener):
    with pytest.raises(RuntimeError, match="delivery verification"):
        bp.run(_home(tmp_path), opener=opener(_replies(sent_chat="-999")),
               choice=lambda xs: xs[0], token="T")


@pytest.mark.parametrize("albums", [[], [ALBUM, dict(ALBUM, id="a3")]])
def test_album_match_must_be_unique(albums):
    with pytest.raises(RuntimeError, match="not unique"):
        bp.pick_album(albums, "burg")


def test_partial_album_page_is_refused(opener):
    fake = opener([json_reply({"assets": {"total": 1, "items": []}})])
    with pytest.raises(RuntimeError, match="scope verification"):
        bp.album_images(bp.Config(), ALBUM, opener=fake)


def test_missing_origin_chat_is_a_failure():
    with pytest.raises(RuntimeError, match="no origin chat"):
        bp.origin_chat([{"id": "5eb0b7dd6e7f", "origin": {}}], "5eb0b7dd6e7f")


def test_main_exits_nonzero_without_jobs_json(tmp_path, capsys):
    assert bp.main(env={"HERMES_HOME": str(tmp_path)}) == 1
    assert capsys.readouterr().out == ""
