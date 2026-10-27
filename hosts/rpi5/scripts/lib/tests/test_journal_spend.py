import json
from datetime import date

from conftest import FakeOpener, FakeResponse
from nicos_scripts.connectors import journal_spend as sp

S = sp.Spend


def json_reply(d):
    return FakeResponse(json.dumps(d).encode())


def test_section_totals_mine_and_joint_apart():
    spends = [S(False, 41.17, "Uber", "3 - Transportation"), S(False, 72.0, "Trattoria", "0 - Food & Drink"),
              S(False, 10.0, "Uber", "3 - Transportation"), S(True, 16.78, "Lidl", "0 - Groceries"),
              S(False, -23.5, "CPAM", "I3 - Health"), S(False, -2000, "TRUSK", "I0 - Work"),
              S(True, -234.25, "AIRBNB", "I7 - Airbnb"), S(False, 600, "PEA", "Investment Contributions")]
    head, lines = sp.spend_section(spends, age_days=10)
    assert head == "123,17 € · 👥 16,78 € en commun"
    assert lines == ["- 🍽 **Trattoria** · 72,00 €", "- 🚕 **Uber** · 51,17 € (2)",
                     "- 👥 🛒 **Lidl** · 16,78 €", "- ↩︎ **Remboursé** · 23,50 €"]


def test_section_marks_a_young_day_and_skips_an_empty_one():
    head, _ = sp.spend_section([S(True, 5, "Monoprix", "0 - Groceries")], age_days=2)
    assert head == "👥 5,00 € en commun · en cours de synchro"
    assert sp.spend_section([S(False, -2000, "TRUSK", "I0 - Work")], age_days=2) is None


def _tx(account, cents, merchant=None, category=None, name="X", transfer=None):
    return {"account": {"name": account}, "signed_amount_cents": cents, "name": name,
            "merchant": {"name": merchant} if merchant else None,
            "category": {"name": category} if category else None, "transfer": transfer}


def test_api_keeps_the_days_spending_and_the_mortgage():
    page1 = {"transactions": [
        _tx("SG - Courant", -1250, "Franprix", "0 - Groceries"),
        _tx("Burgieland", -300, "La Rose", "0 - Food & Drink"),
        _tx("SG - Courant", -2000, name="VIR LYDIA", transfer={"other_account": {"account_type": "depository"}}),
        _tx("PEA", -5000, "Broker")],  # not a configured account
        "pagination": {"page": 1, "total_pages": 2}}
    page2 = {"transactions": [
        _tx("SG - Courant", -90000, name="ECH PRET", transfer={"other_account": {"account_type": "loan"}}),
        _tx("SG - Courant", 2350, "CPAM", "I3 - Health")],
        "pagination": {"page": 2, "total_pages": 2}}
    op = FakeOpener([json_reply(page1), json_reply(page2)])
    spends = sp.day_spends(date(2026, 10, 24), ["SG - Courant"], ["Burgieland"], "http://sure/sure", "k", op)
    assert spends == [S(False, 900.0, "ECH PRET", ""), S(False, 12.5, "Franprix", "0 - Groceries"),
                      S(True, 3.0, "La Rose", "0 - Food & Drink"), S(False, -23.5, "CPAM", "I3 - Health")]
    req = op.requests[0]
    assert req.full_url.startswith("http://sure/sure/api/v1/transactions?start_date=2026-10-24&end_date=2026-10-24")
    assert req.get_header("X-api-key") == "k" and "page=2" in op.requests[1].full_url
