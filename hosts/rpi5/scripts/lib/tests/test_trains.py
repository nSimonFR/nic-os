"""Tests for the train price sources and MCP server.

Nothing here touches the network: sources take an `opener`, the watch logic takes
fake sources, and the DB lives in tmp_path.
"""

import io
import json
import urllib.error

import pytest

from conftest import FakeResponse, json_reply
from nicos_scripts.trains import mcp, sources as src


# ===================================================================
# sources
# ===================================================================


def _row(dep, arr, second="70,00 €", first="94,00 €", segments=1):
    def prices(title, amount):
        whole, dec = amount.split(",")
        return (
            '<div class="r-s-r-travelclass-prices">'
            f'<div class="r-s-r-travelclass-title"><span>{title}</span></div>'
            '<div class="r-s-r-offers-prices"><div class="r-s-r-o-price">'
            f'<div class="r-s-r-o-price-amount">{whole}<span>,{dec}</span></div>'
            "</div></div></div>"
        )

    classes = (prices("2<sup>e</sup> classe", second) if second else "") + prices(
        "1<sup>re</sup> classe", first
    )
    segs = '<div class="j-p-result-j-segment"></div>' * segments
    return (
        f'<div class="r-s-r" data-rsrc_departure="28/11/2026 {dep}" '
        f'data-rsrc_arrival="28/11/2026 {arr}">'
        f'<div class="j-p-result-j-segments">{segs}</div>'
        '<div class="j-p-result-j-duration">Durée: 3h42 en TGV Inoui</div>'
        f'<div class="r-s-r-travelclasses-prices">{classes}</div></div>'
    )


def test_parse_12train_takes_the_second_class_price_and_counts_changes():
    html = (
        _row("14:57", "18:39")
        + _row("16:50", "20:36", second=None, first="120,00 €")
        + _row("07:00", "12:20", segments=3)
    )
    a, b, c = src.parse_12train(html)
    assert (a.departs, a.arrives, a.price, a.changes) == (
        "2026-11-28T14:57",
        "2026-11-28T18:39",
        70.0,
        0,
    )
    assert a.train == "TGV Inoui"
    assert b.price is None  # only a 1st-class fare: not a priced 2nd class
    assert c.changes == 2


def test_parse_12train_ignores_a_page_without_results():
    assert src.parse_12train("<p>Erreur technique</p>") == []
    assert src.parse_12train("") == []


STATIONS = [
    {
        "_u_i_c_station_code": "PT1",
        "name": "Paris toutes gares",
        "synonyms": ["Paris"],
        "is_agglomeration": True,
        "parent": None,
    },
    {
        "_u_i_c_station_code": "87391003",
        "name": "Paris Montparnasse",
        "synonyms": ["Paris"],
        "is_agglomeration": False,
        "parent": "PT1",
    },
    {
        "_u_i_c_station_code": "87474007",
        "name": "Brest",
        "synonyms": ["Brest"],
        "is_agglomeration": False,
        "parent": None,
    },
]


def _ouigo(opener, *replies):
    login = json_reply({"token": "t0k"})
    return src.Ouigo(opener=opener([login, json_reply(STATIONS), *replies]))


def test_ouigo_station_prefers_the_group_for_a_city_and_the_exact_name_otherwise(
    opener,
):
    o = _ouigo(opener)
    assert o.station("Paris") == "PT1"
    assert o.station("paris montparnasse") == "87391003"
    assert o.station("BREST") == "87474007"
    with pytest.raises(LookupError):
        o.station("Atlantis")


def test_ouigo_search_prices_trains_and_marks_sold_out_ones(opener):
    journeys = json_reply(
        {
            "outbound": [
                {
                    "price": 75.0,
                    "service_name": "OUIGO 6701",
                    "departure_station": {
                        "departure_timestamp": "2026-12-20T06:46:00+01:00"
                    },
                    "arrival_station": {
                        "arrival_timestamp": "2026-12-20T10:34:00+01:00"
                    },
                },
                {
                    "price": 120.0,
                    "full": True,
                    "departure_station": {
                        "departure_timestamp": "2026-12-20T18:00:00+01:00"
                    },
                    "arrival_station": {
                        "arrival_timestamp": "2026-12-20T21:40:00+01:00"
                    },
                },
            ]
        }
    )
    fake = opener([json_reply({"token": "t0k"}), json_reply(STATIONS), journeys])
    got = src.Ouigo(opener=fake).search("Paris", "Brest", "2026-12-20")

    assert [(j.departs, j.price, j.train) for j in got] == [
        ("2026-12-20T06:46", 75.0, "OUIGO 6701"),
        ("2026-12-20T18:00", None, "OUIGO"),
    ]
    sent = fake.body_of(-1)
    assert (sent["origin"], sent["destination"], sent["outbound_date"]) == (
        "PT1",
        "87474007",
        "2026-12-20",
    )
    assert fake.last.headers["Authorization"] == "Bearer t0k"


def test_ouigo_calendar_returns_one_price_per_day(opener):
    cal = json_reply(
        [
            {"date": "2026-12-19T00:00:00", "price": 75.0, "is_promo": False},
            {"date": "2026-12-20T00:00:00", "price": None},
        ]
    )
    got = _ouigo(opener, cal).calendar("Paris", "Brest", "2026-12-19", "2026-12-20")
    assert got == [("2026-12-19", 75.0, False), ("2026-12-20", None, False)]


def test_inoui_search_warms_up_resolves_stations_and_dedupes_across_hours(opener):
    page = json_reply(
        {"search_results": {"rail_search_results": _row("14:57", "18:39")}}
    )
    fake = opener(
        [
            lambda: FakeResponse(b"<html>"),
            json_reply([{"code": "X", "label": "Paris (toutes gares)"}]),
            json_reply([{"code": "FRBES", "label": "Brest"}]),
            page,
        ]
    )
    slept = []
    got = src.Inoui(opener=fake, sleep=slept.append, hours=(9, 13)).search(
        "Paris", "Brest", "2026-11-28"
    )

    assert [(j.departs, j.price) for j in got] == [("2026-11-28T14:57", 70.0)]
    posted = [r.data.decode() for r in fake.requests if r.data]
    assert "form[origin]=Paris%20(toutes%20gares)" in posted[2]
    assert "form[departure_date]=28/11/2026" in posted[2].replace("%2F", "/")
    assert "form[departure_hour]=13" in posted[3]
    assert slept  # never hammers the site


def test_inoui_surfaces_the_sites_own_error(opener):
    fake = opener(
        [
            lambda: FakeResponse(b""),
            json_reply([{"label": "Paris"}]),
            json_reply([{"label": "Brest"}]),
            json_reply({"errors": [{"message": "Erreur technique"}]}),
        ]
    )
    with pytest.raises(RuntimeError, match="Erreur technique"):
        src.Inoui(opener=fake, sleep=lambda s: None, hours=(9,)).search(
            "Paris", "Brest", "2026-11-28"
        )


class FakeSource:
    def __init__(self, name, *days):
        self.name, self.days, self.calls = name, list(days), 0

    def search(self, origin, destination, date):
        day = self.days[min(self.calls, len(self.days) - 1)]
        self.calls += 1
        if isinstance(day, Exception):
            raise day
        return day


def J(price, source="ouigo", hhmm="06:46", changes=0):
    return src.Journey(source, f"2026-12-20T{hhmm}", "2026-12-20T10:34", price, changes)


# ===================================================================
# MCP server
# ===================================================================


@pytest.fixture
def handlers():
    return mcp.Handlers(
        {
            "ouigo": FakeSource("ouigo", [J(75), J(99, hhmm="11:15", changes=1)]),
            "inoui": FakeSource("inoui", []),
        }
    )


def _call(handlers, name, **args):
    reply = mcp.handle(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        },
        handlers,
    )
    return reply["result"]


def _data(result):
    return json.loads(result["content"][0]["text"])


def test_initialize_echoes_the_clients_protocol_and_lists_every_tool(handlers):
    init = mcp.handle(
        {"id": 1, "method": "initialize", "params": {"protocolVersion": "2099-01-01"}},
        handlers,
    )
    assert init["result"]["protocolVersion"] == "2099-01-01"
    assert mcp.handle({"method": "notifications/initialized"}, handlers) is None
    tools = mcp.handle({"id": 2, "method": "tools/list"}, handlers)["result"]["tools"]
    assert {t["name"] for t in tools} == {"train_prices", "train_calendar"}
    assert all(t["inputSchema"]["type"] == "object" for t in tools)


def test_every_declared_tool_has_a_handler():
    assert all(callable(getattr(mcp.Handlers, name)) for name in mcp.TOOLS)


def test_train_prices_hides_trains_with_changes_by_default(handlers):
    args = {"origin": "Paris", "destination": "Brest", "date": "2026-12-20"}
    got = _data(_call(handlers, "train_prices", **args))
    assert [t["price"] for t in got["trains"]] == [75.0]
    got = _data(_call(handlers, "train_prices", max_changes=1, **args))
    assert len(got["trains"]) == 2


def test_a_dead_source_is_reported_without_hiding_the_other():
    h = mcp.Handlers(
        {
            "ouigo": FakeSource("ouigo", [J(75)]),
            "inoui": FakeSource("inoui", urllib.error.URLError("down")),
        }
    )
    got = _data(
        _call(h, "train_prices", origin="Paris", destination="Brest", date="2026-12-20")
    )
    assert [t["price"] for t in got["trains"]] == [75.0]
    assert "inoui" in got["errors"]


def test_a_failing_tool_is_an_error_result_not_a_dead_server(handlers):
    result = _call(
        handlers,
        "train_prices",
        origin="Paris",
        destination="Brest",
        date="2026-12-20",
        sources=["sncf"],
    )
    assert result["isError"] and "source indisponible" in result["content"][0]["text"]
    assert mcp.handle(
        {"id": 3, "method": "tools/call", "params": {"name": "x"}}, handlers
    )["error"]
    assert mcp.handle({"id": 4, "method": "nope"}, handlers)["error"]["code"] == -32601


def test_train_calendar_rejects_a_range_over_62_days(handlers):
    result = _call(
        handlers,
        "train_calendar",
        origin="Paris",
        destination="Brest",
        start="2026-12-01",
        end="2027-03-01",
    )
    assert result["isError"]


def test_serve_speaks_newline_delimited_json_rpc(handlers):
    stdin = io.StringIO(
        '{"id":1,"method":"ping"}\n\nnot json\n{"method":"notifications/initialized"}\n'
    )
    stdout = io.StringIO()
    mcp.serve(handlers, stdin, stdout)
    first, second = (json.loads(line) for line in stdout.getvalue().splitlines())
    assert first == {"jsonrpc": "2.0", "id": 1, "result": {}}
    assert second["error"]["code"] == -32700
