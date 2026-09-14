"""The guard that matters here is `select_mappings` refusing ambiguous names.

A rule is applied silently on every future sync, so a wrong one is worse than
no rule: it mislabels spend forever and the LLM never gets a chance to try.
The real data that motivated this had `Fannie Jacquemin` spread over seven
categories in eight transactions — hence the dominance test below.
"""

import pytest

from nicos_scripts.sure import derive_rules as dr


def cfg(**kw):
    return dr.Config(**{"dry_run": True, **kw})


# name, target, top, total, pending
def row(name, target="cat-1", top=8, total=10, pending=3):
    return [name, target, str(top), str(total), str(pending)]


class TestSelectMappings:
    def test_accepts_a_dominant_well_attested_name(self):
        accepted, rejected = dr.select_mappings([row("Auchan", top=9, total=10)],
                                                set(), 0.8, 2)
        assert [m["name"] for m in accepted] == ["Auchan"]
        assert rejected == []

    def test_rejects_an_ambiguous_name(self):
        # 2 of 8 — the Fannie Jacquemin shape.
        accepted, rejected = dr.select_mappings([row("Fannie Jacquemin", top=2, total=8)],
                                                set(), 0.8, 2)
        assert accepted == []
        assert "ambiguous" in rejected[0][1]

    def test_rejects_a_single_observation(self):
        accepted, rejected = dr.select_mappings([row("Steda", top=1, total=1)],
                                                set(), 0.8, 2)
        assert accepted == []
        assert "observation" in rejected[0][1]

    def test_is_idempotent_against_existing_rules(self):
        accepted, rejected = dr.select_mappings([row("Auchan", top=9, total=10)],
                                                {"Auchan"}, 0.8, 2)
        assert accepted == []
        assert rejected[0][1] == "already has a rule"

    def test_boundary_dominance_is_inclusive(self):
        accepted, _ = dr.select_mappings([row("Boost", top=8, total=10)], set(), 0.8, 2)
        assert len(accepted) == 1

    def test_carries_pending_count_for_reporting(self):
        accepted, _ = dr.select_mappings([row("Auchan", top=9, total=10, pending=15)],
                                         set(), 0.8, 2)
        assert accepted[0]["pending"] == 15


class TestSqlLiteral:
    def test_escapes_apostrophes(self):
        # Real name from this install: `Aux Saveurs D'ol`.
        assert dr.sql_literal("Aux Saveurs D'ol") == "'Aux Saveurs D''ol'"

    def test_rejects_nul(self):
        with pytest.raises(ValueError):
            dr.sql_literal("bad\x00name")

    def test_plain_name_round_trips(self):
        assert dr.sql_literal("Auchan") == "'Auchan'"


class TestInsertSql:
    def test_emits_rule_condition_and_action_in_one_transaction(self):
        sql = dr.insert_sql("fam-1", "category",
                            {"name": "Auchan", "target": "cat-9"},
                            new_uuid=lambda: "rule-1")
        assert sql.startswith("BEGIN;") and sql.endswith("COMMIT;")
        assert "INSERT INTO rules" in sql
        assert "INSERT INTO rule_conditions" in sql
        assert "INSERT INTO rule_actions" in sql
        assert "'set_transaction_category'" in sql
        assert "'cat-9'" in sql
        # Same rule id threaded through all three rows.
        assert sql.count("'rule-1'") == 3

    def test_merchant_kind_uses_the_merchant_action(self):
        sql = dr.insert_sql("fam-1", "merchant", {"name": "X", "target": "m-1"},
                            new_uuid=lambda: "r")
        assert "'set_transaction_merchant'" in sql

    def test_quotes_a_name_with_an_apostrophe(self):
        sql = dr.insert_sql("fam-1", "category",
                            {"name": "Aux Saveurs D'ol", "target": "c"},
                            new_uuid=lambda: "r")
        assert "'Aux Saveurs D''ol'" in sql


class TestConfig:
    def test_defaults_to_dry_run_on_empty_env(self):
        # CLAUDE.md: a Config built with no env must not be able to write.
        assert dr.Config.from_env({}).dry_run is True

    def test_apply_opts_in(self):
        assert dr.Config.from_env({"APPLY": "1"}).dry_run is False

    def test_garbage_dominance_falls_back(self):
        assert dr.Config.from_env({"MIN_DOMINANCE": "abc"}).min_dominance == \
            dr.DEFAULT_MIN_DOMINANCE

    def test_reads_overrides(self):
        c = dr.Config.from_env({"MIN_DOMINANCE": "0.95", "MIN_OBSERVATIONS": "5"})
        assert (c.min_dominance, c.min_observations) == (0.95, 5)


def fake_psql(candidates, existing=(), written=None):
    """Dispatch on the query, not on a substring both queries happen to share.

    `candidates_sql` contains "SELECT DISTINCT" too (in its `pending` CTE), so
    matching on that routed the candidate query to the existing-rules branch
    and silently returned no candidates — the tests then passed vacuously.
    """
    def run(cmd):
        sql = cmd[-1]
        if sql.lstrip().startswith("BEGIN;"):
            if written is not None:
                written.append(sql)
            return ""
        if "FROM rule_conditions" in sql:
            return "".join(f"{n}\n" for n in existing)
        assert "WITH hist AS" in sql, f"unexpected query: {sql[:60]}"
        return "".join("\x1f".join(r) + "\n" for r in candidates)
    return run


CANDIDATES = [
    ["Auchan", "cat-1", "9", "10", "4"],   # dominant, well attested -> accepted
    ["Steda", "cat-2", "1", "1", "2"],     # single observation      -> skipped
]


class TestDerive:
    def test_dry_run_writes_nothing(self):
        written = []
        n = dr.derive(fake_psql(CANDIDATES, written=written), cfg(), "fam-1",
                      kinds=("category",), log=lambda m: None)
        assert n == 0 and written == []

    def test_apply_writes_one_rule_per_accepted_name(self):
        written = []
        n = dr.derive(fake_psql(CANDIDATES, written=written), cfg(dry_run=False),
                      "fam-1", kinds=("category",), log=lambda m: None,
                      new_uuid=lambda: "r")
        assert n == 1 and len(written) == 1
        assert "'Auchan'" in written[0]
        assert "'Steda'" not in written[0]

    def test_existing_rule_suppresses_a_write(self):
        written = []
        n = dr.derive(fake_psql(CANDIDATES, existing=["Auchan"], written=written),
                      cfg(dry_run=False), "fam-1", kinds=("category",),
                      log=lambda m: None, new_uuid=lambda: "r")
        assert n == 0 and written == []
