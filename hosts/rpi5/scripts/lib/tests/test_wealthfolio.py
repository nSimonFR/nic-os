"""Sure -> Wealthfolio sync.

The interesting cases are the ones where a wrong answer is silent: a crypto
position given a zero cost basis reads as a 100% gain, an unresolved symbol
that imports anyway reads as a sale, and a dry run that posts reads as a
successful sync. Each of those has a test here.
"""

import json

from nicos_scripts.connectors import wealthfolio as wf
from tests.conftest import FakeOpener, FakeResponse, json_reply


def cfg(**kw):
    return wf.Config(**kw)


def fake_run(tables):
    """A `run` that dispatches on which table the SQL mentions.

    Matching on the query text rather than on call order keeps the tests from
    silently passing when the module reorders its reads.
    """

    def run(cmd):
        sql = cmd[-1]
        for needle, rows in tables.items():
            if needle in sql:
                return "".join("\x1f".join(r) + "\n" for r in rows)
        return ""

    return run


# ── symbol mapping ───────────────────────────────────────────────────────────

def test_crypto_tickers_map_to_usd_pairs():
    assert wf.map_symbol("CRYPTO:BTC") == "BTC-USD"
    assert wf.map_symbol("CRYPTO:ETH") == "ETH-USD"
    assert wf.map_symbol("CRYPTO:SD") == "SD-USD"
    # ETHX is the one that would have needed a table entry under a hand-listed
    # mapping; the rule covers it.
    assert wf.map_symbol("CRYPTO:ETHX") == "ETHX-USD"


def test_non_crypto_tickers_pass_through_unchanged():
    for ticker in ("ESE.PA", "PUST.PA", "SXRT.DE", "MAGR.DE", "ETH-USD",
                   "0P0000KXZM.F", "0P0000Q2W2.F", "0P0000VQH6.F"):
        assert wf.map_symbol(ticker) == ticker


def test_an_override_wins_over_the_crypto_rule():
    wf.SYMBOL_OVERRIDES["CRYPTO:WEIRD"] = "WEIRD-EUR"
    try:
        assert wf.map_symbol("CRYPTO:WEIRD") == "WEIRD-EUR"
    finally:
        del wf.SYMBOL_OVERRIDES["CRYPTO:WEIRD"]


# ── reading Sure ─────────────────────────────────────────────────────────────

POSITION_ROWS = [
    ["PEA", "2026-08-14", "ESE.PA", "269.0", "EUR", "26.13", "XPAR"],
    ["Bitcoin", "2026-08-14", "CRYPTO:BTC", "0.00287", "USD", "", ""],
]


def test_cost_basis_is_carried_through_for_securities():
    got = wf.sure_positions(cfg(), fake_run({"FROM holdings": POSITION_ROWS}), "")
    pea = got[("PEA", "2026-08-14")][0]
    assert pea["avgCost"] == "26.13"


def test_sures_exchange_mic_is_never_forwarded():
    """Sure says "GER" for Frankfurt, which is not a MIC.

    Passing it pins the asset to an exchange Yahoo has never heard of: the
    quantity still imports, the price comes back empty, and the position
    silently values at zero. Wealthfolio infers XETR from the .DE suffix.
    """
    rows = [["Finary Life", "2026-08-14", "MAGR.DE", "48.49", "EUR", "", "GER"]]
    got = wf.sure_positions(cfg(), fake_run({"FROM holdings": rows}), "")
    assert "exchangeMic" not in got[("Finary Life", "2026-08-14")][0]


def test_crypto_positions_omit_avg_cost_rather_than_sending_zero():
    got = wf.sure_positions(cfg(), fake_run({"FROM holdings": POSITION_ROWS}), "")
    btc = got[("Bitcoin", "2026-08-14")][0]
    assert "avgCost" not in btc
    assert btc["symbol"] == "BTC-USD"
    # Sure stores the account currency; the pair is quoted in USD regardless.
    assert btc["currency"] == "USD"


def test_backfill_bounds_the_query_and_drops_the_latest_only_clause():
    seen = {}

    def run(cmd):
        seen["sql"] = cmd[-1]
        return ""

    wf.sure_positions(cfg(), run, "2025-04-01")
    assert "h.date >= DATE '2025-04-01'" in seen["sql"]
    assert "max(date)" not in seen["sql"]


def test_without_backfill_only_the_latest_date_is_read():
    seen = {}

    def run(cmd):
        seen["sql"] = cmd[-1]
        return ""

    wf.sure_positions(cfg(), run, "")
    assert "max(date)" in seen["sql"]


def test_property_and_loan_become_alternative_assets():
    rows = [["Maison", "Property", "EUR", "338531.0"],
            ["Prêt", "Loan", "EUR", "314229.0"]]
    got = wf.sure_alternatives(cfg(), fake_run({"'Property', 'Loan'": rows}))
    assert [a["kind"] for a in got] == ["property", "liability"]


# ── writing Wealthfolio ──────────────────────────────────────────────────────

def test_unresolved_symbol_aborts_the_account_without_importing(logged):
    lines, log = logged
    opener = FakeOpener([json_reply({"symbols": [{"symbol": "NOPE", "found": False}]})])
    client = wf.Wealthfolio("http://wf", opener=opener)
    n = wf.import_snapshots(client, log, "acct", [{"date": "2026-08-14", "positions": []}],
                            dry_run=False)
    assert n == 0
    assert any("unresolved symbols" in line for line in lines)
    # The check ran; the import did not.
    assert [r.get_full_url() for r in opener.requests] == [
        "http://wf/api/v1/snapshots/import/check"
    ]


def test_resolved_asset_ids_are_carried_into_the_import(logged):
    _, log = logged
    opener = FakeOpener([
        json_reply({"symbols": [{"symbol": "ESE.PA", "found": True, "assetId": "a-1"}]}),
        json_reply({"snapshotsImported": 1, "snapshotsFailed": 0}),
    ])
    client = wf.Wealthfolio("http://wf", opener=opener)
    snaps = [{"date": "2026-08-14", "positions": [{"symbol": "ESE.PA", "quantity": "269"}]}]
    assert wf.import_snapshots(client, log, "acct", snaps, dry_run=False) == 1
    assert opener.body_of(-1)["snapshots"][0]["positions"][0]["assetId"] == "a-1"


def test_dry_run_checks_but_never_imports(logged):
    lines, log = logged
    opener = FakeOpener([json_reply({"symbols": []})])
    client = wf.Wealthfolio("http://wf", opener=opener)
    assert wf.import_snapshots(client, log, "acct", [{"date": "d", "positions": []}],
                               dry_run=True) == 0
    assert all("/snapshots/import" != r.get_full_url().split("/api/v1")[-1]
               for r in opener.requests)
    assert any("DRY would import" in line for line in lines)


def test_a_closed_position_is_simply_absent_from_the_next_snapshot(logged):
    """No delete call exists, and none is needed: the snapshot IS the state."""
    _, log = logged
    opener = FakeOpener([
        json_reply({"symbols": [{"symbol": "ESE.PA", "found": True, "assetId": "a-1"}]}),
        json_reply({"snapshotsImported": 2, "snapshotsFailed": 0}),
    ])
    client = wf.Wealthfolio("http://wf", opener=opener)
    snaps = [
        {"date": "2026-08-13", "positions": [{"symbol": "ESE.PA", "quantity": "269"}]},
        {"date": "2026-08-14", "positions": []},
    ]
    assert wf.import_snapshots(client, log, "acct", snaps, dry_run=False) == 2
    assert opener.body_of(-1)["snapshots"][1]["positions"] == []


def test_existing_account_is_reused_rather_than_duplicated(logged):
    _, log = logged
    opener = FakeOpener([json_reply([{"id": "existing-id", "name": "PEA"}])])
    client = wf.Wealthfolio("http://wf", opener=opener)
    got = wf.ensure_account(client, log, "PEA", "SECURITIES", "EUR", "Investments", False)
    assert got == "existing-id"
    assert len(opener.requests) == 1  # the GET only; no POST


def test_a_new_account_is_created_in_holdings_tracking_mode(logged):
    _, log = logged
    opener = FakeOpener([json_reply([]), json_reply({"id": "new-id"})])
    client = wf.Wealthfolio("http://wf", opener=opener)
    assert wf.ensure_account(client, log, "PEA", "SECURITIES", "EUR", "Investments", False) == "new-id"
    # TRANSACTIONS would make Wealthfolio derive holdings from a trade history
    # that does not exist, silently zeroing every position.
    assert opener.body_of(-1)["trackingMode"] == "HOLDINGS"


def test_the_loan_is_linked_to_the_property(logged):
    _, log = logged
    opener = FakeOpener([
        json_reply([]),                      # GET /alternative-holdings
        json_reply({"assetId": "prop-1"}),   # POST property
        json_reply({"assetId": "loan-1"}),   # POST liability
        json_reply({}),                      # POST link-liability
    ])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.sync_alternatives(client, log, [
        {"name": "Maison", "kind": "property", "currency": "EUR", "value": "338531"},
        {"name": "Prêt", "kind": "liability", "currency": "EUR", "value": "314229"},
    ], "2026-08-14", dry_run=False)
    assert opener.last.get_full_url() == "http://wf/api/v1/alternative-assets/loan-1/link-liability"
    assert json.loads(opener.last.data.decode())["targetAssetId"] == "prop-1"


def test_alternative_valuations_use_the_injected_date_not_the_clock(logged):
    _, log = logged
    opener = FakeOpener([
        json_reply([{"id": "prop-1", "name": "Maison"}]),
        json_reply({}),
    ])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.sync_alternatives(client, log, [
        {"name": "Maison", "kind": "property", "currency": "EUR", "value": "340000"},
    ], "2026-01-02", dry_run=False)
    assert opener.body_of(-1)["date"] == "2026-01-02"


# ── main() ───────────────────────────────────────────────────────────────────

def test_missing_password_returns_1_before_touching_anything():
    calls = []
    assert wf.main(env={}, run=lambda cmd: calls.append(cmd) or "") == 1
    assert calls == []


def test_dry_run_is_off_only_for_the_exact_string_zero():
    assert wf.Config.from_env({"DRY_RUN": "0"}).dry_run is False
    for value in ("1", "", "false", "no", "TRUE"):
        assert wf.Config.from_env({"DRY_RUN": value}).dry_run is True


def test_config_with_no_env_cannot_write():
    assert wf.Config().dry_run is True


def test_the_session_cookie_is_carried_by_hand_not_by_a_jar():
    """WF_COOKIE_SECURE=true + a plaintext loopback hop = an empty cookie jar.

    http.cookiejar correctly refuses to store a Secure cookie seen over HTTP,
    so a CookieProcessor silently drops the session and every later call 401s.
    """
    import email.message

    class ResponseWithCookie(FakeResponse):
        def __init__(self, body):
            super().__init__(body)
            self.headers = email.message.Message()
            self.headers["Set-Cookie"] = (
                "wf_session=tok-123; HttpOnly; SameSite=Lax; Secure; Path=/api"
            )

    opener = FakeOpener([
        lambda: ResponseWithCookie(b'{"authenticated":true}'),
        json_reply([]),
    ])
    client = wf.Wealthfolio("http://wf", opener=opener)
    client.login("pw")
    client.accounts()
    assert opener.last.get_header("Cookie") == "wf_session=tok-123"


def test_positions_and_cash_for_one_date_land_in_one_snapshot():
    """The earlier version emitted cash in a second pass guarded by
    `if name not in by_account`, so exactly one cash date per account survived
    and every other balance was dropped — a savings account read as a
    five-figure negative."""
    positions = {("PEA", "2026-08-14"): [{"symbol": "ESE.PA", "quantity": "269"}]}
    cash = {("PEA", "2026-08-14"): {"EUR": "50"}, ("PEA", "2026-08-13"): {"EUR": "40"}}
    got = wf.build_snapshots(positions, cash)
    assert [s["date"] for s in got["PEA"]] == ["2026-08-13", "2026-08-14"]
    latest = got["PEA"][-1]
    assert latest["positions"][0]["symbol"] == "ESE.PA"
    assert latest["cashBalances"] == {"EUR": "50"}


def test_every_cash_date_survives_the_merge():
    cash = {("Livret A", d): {"EUR": "1"} for d in ("2026-08-12", "2026-08-13", "2026-08-14")}
    got = wf.build_snapshots({}, cash)
    assert len(got["Livret A"]) == 3
