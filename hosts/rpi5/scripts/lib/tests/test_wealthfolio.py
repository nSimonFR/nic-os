"""Sure -> Wealthfolio sync.

The interesting cases are the ones where a wrong answer is silent: a crypto
position given a zero cost basis reads as a 100% gain, an unresolved symbol
that imports anyway reads as a sale, and a dry run that posts reads as a
successful sync. Each of those has a test here.
"""

import io
import json

import pytest

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
    rows = [["Maison", "Property", "EUR", "338531.0", "2025-02-14", "325000.0"],
            ["Prêt", "Loan", "EUR", "314229.0", "2025-03-01", "325000.0"]]
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


def test_snapshots_are_sorted_by_date():
    positions = {
        ("PEA", "2026-08-14"): [{"symbol": "ESE.PA", "quantity": "269"}],
        ("PEA", "2026-08-13"): [{"symbol": "ESE.PA", "quantity": "269"}],
    }
    got = wf.build_snapshots(positions)
    assert [s["date"] for s in got["PEA"]] == ["2026-08-13", "2026-08-14"]


def test_cash_accounts_are_not_mirrored_at_all():
    """Current accounts, savings and the card stay in Sure — mirroring them
    created a second place for the same balance to be slightly wrong in."""
    assert "Depository" not in wf.ACCOUNT_TYPES
    assert "CreditCard" not in wf.ACCOUNT_TYPES
    assert not hasattr(wf, "sure_cash")


# ── trades and goals ─────────────────────────────────────────────────────────

TRADE_ROWS = [
    ["PEA", "ESE.PA", "2025-04-01", "269.0", "26.96", "EUR"],
    ["Bitcoin", "CRYPTO:BTC", "2026-06-15", "0.00287", "66538.47", "USD"],
]


def test_trades_carry_their_real_date_and_price():
    got = wf.sure_trades(cfg(), fake_run({"FROM trades": TRADE_ROWS}))
    assert got["PEA"][0] == {
        "symbol": "ESE.PA", "date": "2025-04-01",
        "quantity": "269.0", "price": "26.96", "currency": "EUR"}
    # Crypto tickers map the same way they do for snapshots.
    assert got["Bitcoin"][0]["symbol"] == "BTC-USD"


def test_a_deposit_precedes_the_buys_so_cash_never_goes_negative(logged):
    _, log = logged
    opener = FakeOpener([json_reply({"id": "a"})])
    client = wf.Wealthfolio("http://wf", opener=opener)
    n = wf.import_trades(client, log, "acct", [
        {"symbol": "ESE.PA", "date": "2025-04-01", "quantity": "269", "price": "26.96",
         "currency": "EUR"},
    ], dry_run=False)
    assert n == 1
    bodies = [opener.body_of(i) for i in range(len(opener.requests))]
    assert bodies[0]["activityType"] == "DEPOSIT"
    assert bodies[0]["amount"] == 7252.24        # 269 * 26.96
    assert bodies[0]["activityDate"] == "2025-04-01T00:00:00Z"
    assert bodies[1]["activityType"] == "BUY"
    assert bodies[1]["unitPrice"] == "26.96"     # the REAL price, not a snapshot value


def test_a_transaction_tracked_account_is_created_in_transactions_mode(logged):
    _, log = logged
    opener = FakeOpener([json_reply([]), json_reply({"id": "new"})])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.ensure_account(client, log, "PEA", "SECURITIES", "EUR", "Investments", False,
                      tracking_mode="TRANSACTIONS")
    # TRANSACTIONS is what makes TWR/IRR computable; HOLDINGS refuses both.
    assert opener.body_of(-1)["trackingMode"] == "TRANSACTIONS"


def test_portfolios_follow_the_account_groups(logged):
    _, log = logged
    opener = FakeOpener([json_reply([]), json_reply({"id": "p1"})])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.sync_portfolios(client, log, {"Crypto": ["a2", "a1"]}, dry_run=False)
    body = opener.body_of(-1)
    assert body["name"] == "Crypto"
    assert body["accountIds"] == ["a1", "a2"]


def test_an_empty_group_is_skipped_not_created(logged):
    """The server rejects a portfolio with no accounts."""
    _, log = logged
    opener = FakeOpener([json_reply([])])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.sync_portfolios(client, log, {"Crypto": []}, dry_run=False)
    assert len(opener.requests) == 1  # the GET only


def test_a_duplicate_activity_is_not_an_error(logged):
    """Activities are not upserted like snapshots — the server answers 400 on a
    re-post. That 400 IS the idempotency guarantee, so a second timer run must
    treat it as "already there" rather than aborting the account."""
    import urllib.error

    def duplicate(req, timeout=None):
        raise urllib.error.HTTPError(
            req.full_url, 400, "Bad Request", {},
            io.BytesIO(b'{"code":400,"message":"Duplicate activity detected."}'))

    _, log = logged
    client = wf.Wealthfolio("http://wf", opener=duplicate)
    assert wf.import_trades(client, log, "acct", [
        {"symbol": "ESE.PA", "date": "2025-04-01", "quantity": "269",
         "price": "26.96", "currency": "EUR"},
    ], dry_run=False) == 0


def test_a_real_error_still_raises(logged):
    import urllib.error

    def boom(req, timeout=None):
        raise urllib.error.HTTPError(
            req.full_url, 400, "Bad Request", {},
            io.BytesIO(b'{"code":400,"message":"Invalid symbol"}'))

    _, log = logged
    client = wf.Wealthfolio("http://wf", opener=boom)
    try:
        wf.import_trades(client, log, "acct", [
            {"symbol": "NOPE", "date": "2025-04-01", "quantity": "1",
             "price": "1", "currency": "EUR"}], dry_run=False)
    except urllib.error.HTTPError:
        return
    raise AssertionError("a non-duplicate 400 must propagate")


def test_updating_a_portfolio_sends_the_id_in_the_body_too(logged):
    """The handler deserialises a full Portfolio; path-only id 422s."""
    _, log = logged
    opener = FakeOpener([
        json_reply([{"id": "p1", "name": "Crypto", "accountIds": ["a1"]}]),
        json_reply({}),
    ])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.sync_portfolios(client, log, {"Crypto": ["a1", "a2"]}, dry_run=False)
    assert opener.last.get_method() == "PUT"
    assert opener.body_of(-1)["id"] == "p1"
    assert opener.body_of(-1)["accountIds"] == ["a1", "a2"]


# ── wallet grouping ──────────────────────────────────────────────────────────

def test_the_four_accounts_sharing_one_address_group_together():
    """Sure models a wallet as one account PER TOKEN, so address 0x38...b5b7
    appears four times and the portfolio reads as seven wallets when it is two."""
    for name in ("Ethereum (0x38...b5b7)", "Stader (0x38...b5b7)",
                 "Stader ETHx (0x38...b5b7)", "ETH (Stader Staking)",
                 "Ledger Staking", "Bitcoin (bc1q...k6aq)"):
        assert wf.wallet_group(name) == "Ledger"
    assert wf.wallet_group("Ethereum (0x21...756F)") == "Kraken Wallet"


def test_an_ungrouped_account_keeps_its_own_name():
    assert wf.wallet_group("PEA") == "PEA"


def test_the_same_symbol_from_two_wallets_is_summed():
    """A Ledger wallet holds ETH at 0x38 AND ETH via staking — two Sure
    accounts, one holding. Unmerged, the snapshot carries ETH twice and the
    second silently wins."""
    got = wf.merge_positions([
        {"symbol": "ETH-USD", "quantity": "0.04406929", "currency": "USD"},
        {"symbol": "ETH-USD", "quantity": "0.40010000", "currency": "USD"},
        {"symbol": "BTC-USD", "quantity": "0.00287313", "currency": "USD"},
    ])
    by_symbol = {p["symbol"]: p for p in got}
    assert len(got) == 2
    assert float(by_symbol["ETH-USD"]["quantity"]) == pytest.approx(0.44416929)


def test_merged_cost_basis_is_weighted_by_quantity():
    got = wf.merge_positions([
        {"symbol": "ETH-USD", "quantity": "1", "avgCost": "100"},
        {"symbol": "ETH-USD", "quantity": "3", "avgCost": "200"},
    ])
    # (1*100 + 3*200) / 4 = 175 — not (100+200)/2.
    assert float(got[0]["avgCost"]) == pytest.approx(175.0)


def test_one_missing_basis_makes_the_merged_basis_unknown():
    """Averaging over only the priced half would understate what was paid."""
    got = wf.merge_positions([
        {"symbol": "ETH-USD", "quantity": "1", "avgCost": "100"},
        {"symbol": "ETH-USD", "quantity": "3"},
    ])
    assert "avgCost" not in got[0]
    assert float(got[0]["quantity"]) == pytest.approx(4.0)


def test_a_groups_currency_is_the_majority_not_the_first_seen():
    """Five Ledger accounts are USD and "Ledger Staking" is EUR — picking
    arbitrarily would flip the wallet's denomination on sort order."""
    got = wf.group_accounts([
        {"name": "Ledger Staking", "kind": "Crypto", "currency": "EUR", "id": "1"},
        {"name": "Bitcoin (bc1q...k6aq)", "kind": "Crypto", "currency": "USD", "id": "2"},
        {"name": "Ethereum (0x38...b5b7)", "kind": "Crypto", "currency": "USD", "id": "3"},
        {"name": "PEA", "kind": "Investment", "currency": "EUR", "id": "4"},
    ])
    assert got["Ledger"]["currency"] == "USD"
    assert got["Ledger"]["kind"] == "Crypto"
    assert got["PEA"]["currency"] == "EUR"   # ungrouped, untouched


# ── cost basis overrides ─────────────────────────────────────────────────────

def test_an_override_fills_a_basis_sure_does_not_have():
    rows = wf.apply_cost_basis_overrides("Ledger", [
        {"symbol": "BTC-USD", "quantity": "0.00287313"},
    ])
    # EUR 195 over the held quantity, not over what was originally acquired —
    # so it stays right as the position moves.
    assert float(rows[0]["avgCost"]) == pytest.approx(209.88 / 0.00287313)


def test_an_override_never_overwrites_sures_own_basis():
    """Sure is the source of truth; the override only ever fills a gap."""
    rows = wf.apply_cost_basis_overrides("Ledger", [
        {"symbol": "BTC-USD", "quantity": "0.00287313", "avgCost": "1.0"},
    ])
    assert rows[0]["avgCost"] == "1.0"


def test_eth_has_no_override_because_the_data_is_incomplete():
    """0.111 of 0.481 ETH is accounted for; a basis over 23% of a holding would
    render as a ~4x gain — a confident wrong number where blank was honest."""
    assert ("Ledger", "ETH-USD") not in wf.COST_BASIS_OVERRIDES
    rows = wf.apply_cost_basis_overrides("Ledger", [
        {"symbol": "ETH-USD", "quantity": "0.44416929"},
    ])
    assert "avgCost" not in rows[0]


def test_a_zero_quantity_position_does_not_divide_by_zero():
    rows = wf.apply_cost_basis_overrides("Ledger", [
        {"symbol": "BTC-USD", "quantity": "0"},
    ])
    assert "avgCost" not in rows[0]


def test_the_override_reaches_positions_read_from_sure():
    """sure_positions keys on (account, date); passing the whole tuple as the
    account made every lookup miss silently and the basis stayed empty."""
    rows = [["Bitcoin (bc1q...k6aq)", "2026-08-16", "CRYPTO:BTC", "0.00287313",
             "USD", "", ""]]
    got = wf.sure_positions(cfg(), fake_run({"FROM holdings": rows}), "")
    pos = got[("Ledger", "2026-08-16")][0]
    assert float(pos["avgCost"]) == pytest.approx(209.88 / 0.00287313)


def test_alternatives_carry_where_they_started():
    """Without the origin the flat and the mortgage are numbers with no
    history — the app cannot say the property is up or the loan part-repaid."""
    rows = [["Maison", "Property", "EUR", "338531.0", "2025-02-14", "325000.0"]]
    got = wf.sure_alternatives(cfg(), fake_run({"'Property', 'Loan'": rows}))
    assert got[0]["start_date"] == "2025-02-14"
    assert got[0]["start_value"] == "325000.0"


def test_a_new_alternative_sends_its_purchase_date_and_price(logged):
    _, log = logged
    opener = FakeOpener([json_reply([]), json_reply({"assetId": "p1"})])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.sync_alternatives(client, log, [
        {"name": "Maison", "kind": "property", "currency": "EUR",
         "value": "338531.0", "start_date": "2025-02-14", "start_value": "325000.0"},
    ], "2026-08-16", dry_run=False)
    body = opener.body_of(-1)
    assert body["purchaseDate"] == "2025-02-14"
    assert body["purchasePrice"] == "325000.0"
    assert body["currentValue"] == "338531.0"


def test_an_alternative_with_no_history_omits_the_purchase_fields(logged):
    _, log = logged
    opener = FakeOpener([json_reply([]), json_reply({"assetId": "p2"})])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.sync_alternatives(client, log, [
        {"name": "Thing", "kind": "other", "currency": "EUR", "value": "1.0",
         "start_date": None, "start_value": None},
    ], "2026-08-16", dry_run=False)
    assert "purchaseDate" not in opener.body_of(-1)

def test_the_loans_origin_is_restored_after_linking(logged):
    """link-liability REPLACES the metadata object rather than merging, so the
    purchase price and date are collateral — the link returns 204 and the origin
    is silently gone."""
    _, log = logged
    opener = FakeOpener([
        json_reply([]),                        # GET /alternative-holdings
        json_reply({"assetId": "loan"}),       # POST liability
        json_reply({"assetId": "prop"}),       # POST property
        json_reply({}),                        # POST link-liability
        json_reply({}),                        # PUT metadata
    ])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.sync_alternatives(client, log, [
        {"name": "Prêt", "kind": "liability", "currency": "EUR", "value": "314229",
         "start_date": "2025-03-01", "start_value": "325000"},
        {"name": "Maison", "kind": "property", "currency": "EUR", "value": "338531",
         "start_date": "2025-02-14", "start_value": "325000"},
    ], "2026-08-16", dry_run=False)
    assert opener.last.get_full_url().endswith("/alternative-assets/loan/metadata")
    assert json.loads(opener.last.data.decode())["metadata"] == {
        "purchase_price": "325000", "purchase_date": "2025-03-01"}


def test_the_history_is_month_end_not_daily():
    """32 points instead of 928 — the same curve at this resolution, since a
    mortgage amortises monthly and the flat is revalued a few times a year."""
    seen = {}

    def run(cmd):
        seen["sql"] = cmd[-1]
        return ""

    wf.sure_alternative_history(cfg(), run)
    assert "to_char(b.date, 'YYYY-MM')" in seen["sql"]


def test_a_new_alternative_gets_its_curve_backfilled(logged):
    _, log = logged
    opener = FakeOpener([json_reply([]), json_reply({"assetId": "p1"}), json_reply({})])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.sync_alternatives(client, log, [
        {"name": "Maison", "kind": "property", "currency": "EUR", "value": "338531",
         "start_date": "2025-02-14", "start_value": "325000"},
    ], "2026-08-16", dry_run=False,
        history={"Maison": [("2025-02-28", "325000"), ("2025-05-31", "328500")]})
    puts = [r for r in opener.requests if r.get_full_url().endswith("/valuation")]
    assert [json.loads(r.data.decode())["date"] for r in puts] == \
        ["2025-02-28", "2025-05-31"]


def test_an_existing_alternative_is_not_re_backfilled(logged):
    """The points do not change once written — re-pushing 32 valuations every
    morning would be 32 calls to say nothing."""
    _, log = logged
    opener = FakeOpener([json_reply([{"id": "p1", "name": "Maison"}]), json_reply({})])
    client = wf.Wealthfolio("http://wf", opener=opener)
    wf.sync_alternatives(client, log, [
        {"name": "Maison", "kind": "property", "currency": "EUR", "value": "338531",
         "start_date": "2025-02-14", "start_value": "325000"},
    ], "2026-08-16", dry_run=False,
        history={"Maison": [("2025-02-28", "325000"), ("2025-05-31", "328500")]})
    # Only today's valuation, not the whole curve again.
    puts = [json.loads(r.data.decode())["date"] for r in opener.requests
            if r.get_full_url().endswith("/valuation")]
    assert puts == ["2026-08-16"]
