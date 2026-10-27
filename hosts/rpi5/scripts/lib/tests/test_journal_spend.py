from datetime import date

from nicos_scripts.connectors import journal_spend as sp

S = sp.Spend


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


def test_query_keeps_standard_settled_entries_of_the_day():
    seen = []

    def run(cmd):
        seen.append(cmd[cmd.index("-c") + 1])
        return "f\x1f12.5000\x1fFranprix\x1f0 - Groceries\nt\x1f3.0000\x1fLa Rose\x1f0 - Food & Drink"
    spends = sp.day_spends(run, date(2026, 10, 24), ["SG - Courant"], ["Burgieland"])
    assert spends == [S(False, 12.5, "Franprix", "0 - Groceries"), S(True, 3.0, "La Rose", "0 - Food & Drink")]
    sql = seen[0]
    assert "e.date = '2026-10-24'" in sql and "t.kind IN ('standard', 'loan_payment')" in sql and "NOT e.excluded" in sql
    assert "'pending', '') <> 'true'" in sql and "IN ('SG - Courant', 'Burgieland')" in sql
