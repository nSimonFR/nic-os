"""Tests for the train watches: sources, alert rules, cron body + CLI, MCP server.

Nothing here touches the network: sources take an `opener`, the watch logic takes
fake sources, and the DB lives in tmp_path.
"""

import io
import json
import urllib.error
from datetime import datetime

import pytest

from conftest import FakeResponse, json_reply
from nicos_scripts.trains import mcp, sources as src, watch as w

NOW = datetime(2026, 11, 10, 9, 0)


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


# ===================================================================
# watch: store + rules
# ===================================================================


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


@pytest.fixture
def conn(tmp_path):
    c = w.connect(w.Config(db=str(tmp_path / "watch.sqlite3")))
    yield c
    c.close()


def _add(conn, **kw):
    kw.setdefault("now", NOW)
    return w.add_watch(conn, "Paris", "Brest", "2026-12-20", **kw)


def test_add_watch_defaults_to_a_ten_percent_drop_and_slugs_the_id(conn):
    row = _add(conn)
    assert row["id"] == "paris-brest-2026-12-20"
    assert (row["drop_pct"], row["max_price"], row["sources"]) == (
        10.0,
        None,
        "ouigo,inoui",
    )


def test_add_watch_with_a_threshold_adds_no_implicit_drop(conn):
    assert _add(conn, max_price=60)["drop_pct"] is None


@pytest.mark.parametrize(
    "kw, msg",
    [
        ({"max_price": -1}, "positif"),
        ({"drop_pct": 150}, "entre 0 et 100"),
        ({"sources": ["sncf"]}, "source inconnue"),
        ({"depart_after": "6h"}, "HH:MM"),
    ],
)
def test_add_watch_rejects_bad_input(conn, kw, msg):
    with pytest.raises(ValueError, match=msg):
        _add(conn, **kw)


def test_add_watch_rejects_a_past_date_and_a_malformed_one(conn):
    with pytest.raises(ValueError, match="passé"):
        w.add_watch(conn, "Paris", "Brest", "2026-11-01", now=NOW)
    with pytest.raises(ValueError, match="YYYY-MM-DD"):
        w.add_watch(conn, "Paris", "Brest", "20/12/2026", now=NOW)


def test_matches_filters_changes_window_and_unpriced(conn):
    row = _add(conn, depart_after="08:00", depart_before="18:00")
    assert not w.matches(row, J(None, hhmm="10:00"))
    assert not w.matches(row, J(50, hhmm="07:59"))
    assert not w.matches(row, J(50, hhmm="18:01"))
    assert not w.matches(row, J(50, hhmm="10:00", changes=1))
    assert w.matches(row, J(50, hhmm="10:00"))


def test_reasons_threshold_drop_and_silence_after_an_alert(conn):
    row = _add(conn, max_price=80, drop_pct=20)
    assert w.reasons(row, J(79), None) == ["sous votre seuil de 80 €"]
    both = w.reasons(row, J(60), 100)
    assert both == [
        "sous votre seuil de 80 €",
        "-40 % depuis le dernier relevé (100 €)",
    ]
    assert w.reasons(row, J(85), 100) == []  # above the threshold, -15 % < 20 %
    assert w.reasons({**row, "last_alert_price": 60.0}, J(60), 100) == []
    assert w.reasons({**row, "last_alert_price": 60.0}, J(55), 100) != []
    assert w.reasons(row, None, 100) == []


def test_check_alerts_on_a_drop_then_only_on_a_lower_price(conn):
    row = _add(conn)  # drop 10 %
    ouigo = FakeSource("ouigo", [J(100)], [J(80)], [J(80)], [J(70)])
    srcs = {"ouigo": ouigo, "inoui": FakeSource("inoui", [])}

    texts = [
        w.check(conn, w.get_watch(conn, row["id"]), srcs, NOW)[0] for _ in range(4)
    ]

    assert texts[0] == ""  # first check: no baseline
    assert "-20 %" in texts[1] and "OUIGO 06:46 → 10:34 : 80 €" in texts[1]
    assert texts[2] == ""  # same price again
    assert "70 €" in texts[3]  # lower than the last alert


def test_check_rearms_after_the_price_climbs_back(conn):
    row = _add(conn, max_price=80, drop_pct=None)
    ouigo = FakeSource("ouigo", [J(75)], [J(120)], [J(75)])
    srcs = {"ouigo": ouigo, "inoui": FakeSource("inoui", [])}

    texts = [
        w.check(conn, w.get_watch(conn, row["id"]), srcs, NOW)[0] for _ in range(3)
    ]

    assert [bool(t) for t in texts] == [True, False, True]


def test_check_records_history_and_survives_one_dead_source(conn):
    row = _add(conn, max_price=80, drop_pct=None)
    srcs = {
        "ouigo": FakeSource("ouigo", [J(75)]),
        "inoui": FakeSource("inoui", urllib.error.URLError("down")),
    }
    text, errors = w.check(conn, row, srcs, NOW)

    assert "inoui" in errors and "Source indisponible : inoui" in text
    (h,) = w.history(conn, row["id"])
    assert (h["best_price"], h["best_source"], h["n_trains"]) == (75.0, "ouigo", 1)
    assert conn.execute("SELECT count(*) FROM observations").fetchone()[0] == 1


def test_remove_watch_cascades_history(conn):
    row = _add(conn)
    w.check(
        conn,
        row,
        {"ouigo": FakeSource("ouigo", [J(75)]), "inoui": FakeSource("inoui", [])},
        NOW,
    )
    w.remove_watch(conn, row["id"])
    assert conn.execute("SELECT count(*) FROM checks").fetchone()[0] == 0
    with pytest.raises(KeyError):
        w.get_watch(conn, row["id"])


# ===================================================================
# watch: cron body
# ===================================================================


def _cfg(tmp_path):
    return w.Config(db=str(tmp_path / "watch.sqlite3"))


def test_run_is_silent_without_news_and_prints_alerts_otherwise(tmp_path):
    cfg = _cfg(tmp_path)
    conn = w.connect(cfg)
    _add(conn, max_price=80, drop_pct=None)
    conn.close()
    srcs = {
        "ouigo": FakeSource("ouigo", [J(120)], [J(75)]),
        "inoui": FakeSource("inoui", []),
    }

    assert w.run(cfg, srcs, NOW) == ""
    assert "Paris → Brest · 20/12" in w.run(cfg, srcs, NOW)


def test_run_deactivates_watches_whose_date_has_passed(tmp_path):
    cfg = _cfg(tmp_path)
    conn = w.connect(cfg)
    _add(conn)
    conn.close()
    w.run(cfg, {"ouigo": FakeSource("ouigo", [])}, datetime(2026, 12, 21, 9, 0))
    conn = w.connect(cfg)
    assert w.list_watches(conn) == []
    assert len(w.list_watches(conn, active_only=False)) == 1
    conn.close()


def test_run_fails_loudly_only_when_every_source_failed_everywhere(tmp_path):
    cfg = _cfg(tmp_path)
    conn = w.connect(cfg)
    _add(conn)
    conn.close()
    dead = {n: FakeSource(n, OSError("boom")) for n in ("ouigo", "inoui")}
    with pytest.raises(RuntimeError, match="toutes les sources"):
        w.run(cfg, dead, NOW)


def test_main_exits_1_on_total_failure_and_0_with_nothing_to_watch(
    tmp_path, capsys, monkeypatch
):
    env = {
        "TRAIN_WATCH_DB": str(tmp_path / "w.sqlite3"),
        "TRAIN_WATCH_SOURCES": "ouigo",
    }
    assert w.main([], env=env) == 0 and capsys.readouterr().out == ""

    conn = w.connect(w.Config(db=env["TRAIN_WATCH_DB"]))
    _add(conn, sources=["ouigo"])
    conn.close()
    monkeypatch.setattr(
        w, "datetime", type("D", (), {"now": staticmethod(lambda: NOW)})
    )
    monkeypatch.setattr(
        src.Ouigo, "search", lambda self, *a: (_ for _ in ()).throw(OSError("x"))
    )
    assert w.main([], env=env) == 1


# ===================================================================
# MCP server
# ===================================================================


def _cli(tmp_path, capsys, *argv):
    env = {"TRAIN_WATCH_DB": str(tmp_path / "w.sqlite3")}
    code = w.main(list(argv), env=env)
    out = capsys.readouterr()
    return code, out.out, out.err


def test_cli_manages_watches_and_prints_json(tmp_path, capsys):
    code, out, _ = _cli(
        tmp_path, capsys, "add", "Paris", "Brest", "2099-12-20", "--max-price", "80"
    )
    wid = json.loads(out)["id"]
    assert code == 0 and wid == "paris-brest-2099-12-20"
    assert json.loads(_cli(tmp_path, capsys, "list")[1])[0]["max_price"] == 80
    assert json.loads(_cli(tmp_path, capsys, "history", wid)[1]) == []
    assert json.loads(_cli(tmp_path, capsys, "remove", wid)[1]) == {"removed": wid}
    assert json.loads(_cli(tmp_path, capsys, "list")[1]) == []


def test_cli_reports_bad_input_on_stderr_with_exit_2(tmp_path, capsys):
    code, out, err = _cli(tmp_path, capsys, "remove", "nope")
    assert (code, out) == (2, "") and "watch inconnue" in err
    code, _, err = _cli(tmp_path, capsys, "add", "Paris", "Brest", "2000-01-01")
    assert code == 2 and "passé" in err


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
