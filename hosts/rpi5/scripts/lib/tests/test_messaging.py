"""messaging-mcp: the Matrix calls it makes and what the model gets back."""

import io
import json
import urllib.parse

from conftest import FakeOpener, FakeResponse
from nicos_scripts import mcpstdio
from nicos_scripts.messaging import mcp
from nicos_scripts.messaging.matrix import Matrix, token_from_env_file

NICO = "@nico:rpi5.example"


def _reply(payload):
    # A fresh body per call: the last reply repeats, and a read one is empty.
    return lambda: FakeResponse(json.dumps(payload).encode())


def _matrix(*payloads):
    opener = FakeOpener([_reply(p) for p in payloads])
    return Matrix("http://hs", NICO, "tok", opener=opener), opener


def _room(name, network, ts, unread=0, body="salut"):
    state = [{"type": "m.room.name", "content": {"name": name}}]
    if network:
        state.append({"type": "m.bridge", "content": {"protocol": {"id": network}}})
    return {
        "state": {"events": state},
        "timeline": {
            "events": [
                {
                    "type": "m.room.message",
                    "sender": "@whatsapp_33600:rpi5.example",
                    "origin_server_ts": ts,
                    "content": {"msgtype": "m.text", "body": body},
                }
            ]
        },
        "unread_notifications": {"notification_count": unread},
    }


SYNC = {
    "rooms": {
        "join": {
            "!old:x": _room("Maman", "whatsapp", 1_000),
            "!new:x": _room("Léa", "signal", 2_000, unread=3, body="tu viens ?"),
            "!bot:x": _room("WhatsApp bridge bot", None, 3_000),
        }
    }
}


def test_every_call_masquerades_as_nico_with_the_appservice_token():
    m, opener = _matrix({})
    m.sync()
    req = opener.requests[0]
    assert req.get_header("Authorization") == "Bearer tok"
    query = urllib.parse.parse_qs(urllib.parse.urlparse(req.full_url).query)
    assert query["user_id"] == [NICO]


def test_list_chats_keeps_bridged_rooms_newest_first():
    m, _ = _matrix(SYNC)
    chats = mcp.Handlers(m).list_chats()["chats"]
    assert [c["room_id"] for c in chats] == ["!new:x", "!old:x"]
    assert chats[0] == {
        "room_id": "!new:x",
        "name": "Léa",
        "network": "signal",
        "unread": 3,
        "last": {
            "sender": "@whatsapp_33600:rpi5.example",
            "time": "1970-01-01T00:00:02+00:00",
            "body": "tu viens ?",
            "type": "m.text",
        },
    }


def test_list_chats_filters_by_network_and_unread():
    h = mcp.Handlers(_matrix(SYNC)[0])
    assert [c["name"] for c in h.list_chats(network="whatsapp")["chats"]] == ["Maman"]
    assert [c["name"] for c in h.list_chats(unread_only=True)["chats"]] == ["Léa"]


def test_read_chat_is_oldest_first_with_display_names():
    members = {"joined": {"@whatsapp_33600:rpi5.example": {"display_name": "Maman"}}}
    chunk = {
        "chunk": [
            {
                "sender": "@whatsapp_33600:rpi5.example",
                "origin_server_ts": 2_000,
                "content": {"body": "2"},
            },
            {"sender": NICO, "origin_server_ts": 1_000, "content": {"body": "1"}},
        ]
    }
    m, opener = _matrix(members, chunk)
    out = mcp.Handlers(m).read_chat("!r:x", limit=500)
    assert [(x["sender"], x["body"]) for x in out["messages"]] == [
        (NICO, "1"),
        ("Maman", "2"),
    ]
    query = urllib.parse.parse_qs(
        urllib.parse.urlparse(opener.requests[1].full_url).query
    )
    assert query["limit"] == ["200"] and query["dir"] == ["b"]


def test_search_returns_room_and_body():
    hit = {
        "room_id": "!r:x",
        "sender": NICO,
        "origin_server_ts": 0,
        "content": {"body": "loyer"},
    }
    m, opener = _matrix(
        {"search_categories": {"room_events": {"results": [{"result": hit}]}}}
    )
    out = mcp.Handlers(m).search_messages("loyer")
    assert out["results"][0]["room_id"] == "!r:x"
    assert (
        json.loads(opener.requests[0].data)["search_categories"]["room_events"][
            "search_term"
        ]
        == "loyer"
    )


def test_send_puts_a_text_event_and_refuses_an_empty_one():
    m, opener = _matrix({"event_id": "$e"})
    h = mcp.Handlers(m)
    assert h.send_message("!r:x", "j'arrive") == {"event_id": "$e"}
    req = opener.requests[0]
    assert req.get_method() == "PUT"
    assert "/rooms/%21r%3Ax/send/m.room.message/" in req.full_url
    assert json.loads(req.data) == {"msgtype": "m.text", "body": "j'arrive"}
    reply = mcpstdio.handle(
        {
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "send_message",
                "arguments": {"room_id": "!r:x", "text": " "},
            },
        },
        mcp.SEND_TOOLS,
        h,
        mcp.SERVER,
        lambda _m: None,
    )
    assert reply["result"]["isError"] is True


def test_read_and_send_servers_expose_disjoint_tools():
    def tools(argv):
        out = io.StringIO()
        mcp.main(
            argv,
            matrix=_matrix({})[0],
            stdin=io.StringIO('{"id":1,"method":"tools/list"}\n'),
            stdout=out,
        )
        return {t["name"] for t in json.loads(out.getvalue())["result"]["tools"]}

    assert tools([]) == {"list_chats", "read_chat", "search_messages"}
    assert tools(["--send"]) == {"send_message"}


def test_token_is_read_from_the_setup_env_file(tmp_path):
    f = tmp_path / "doublepuppet.env"
    f.write_text("DOUBLEPUPPET_TOKEN=abc\nDOUBLEPUPPET_HS_TOKEN=def\n")
    assert token_from_env_file(f) == "abc"


def test_config_without_env_has_no_user():
    assert mcp.Config.from_env({}).user_id == ""
    assert mcp.main([], env={}) == 2
