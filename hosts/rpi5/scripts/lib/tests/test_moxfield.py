"""moxfield-sync: the guards and the reconciliation arithmetic.

This is the riskiest file in the repo — it deletes rows from a 618-card collection
and there is no soft-delete anywhere in ShowMyCards. Every test below stands for a
way it could destroy data:

  * the prune ceiling (a renamed binder looks exactly like "sold everything")
  * the truncated / private / empty collection checks
  * the language remap, whose absence churned 180 rows on every single run
  * dry-run actually meaning dry
"""

import json
import sqlite3
import urllib.error

import pytest
from conftest import FakeOpener, json_reply

from nicos_scripts.connectors import moxfield as mox

# ── fixtures ──────────────────────────────────────────────────────────────────


def make_db(tmp_path, cards, inventories=()):
    """A stand-in for the ShowMyCards sqlite catalogue.

    `cards`: (scryfall_id, oracle_id, set_code, collector_number, lang).
    `inventories`: (scryfall_id, quantity). Only the columns this script reads.
    """
    path = tmp_path / "smc.db"
    con = sqlite3.connect(str(path))
    con.execute(
        "create table cards (scryfall_id text primary key, oracle_id text,"
        " set_code text, raw_json text)"
    )
    con.execute(
        "create table inventories (id integer primary key, scryfall_id text,"
        " quantity integer)"
    )
    for sid, oid, code, cn, lang in cards:
        con.execute(
            "insert into cards values (?,?,?,?)",
            (sid, oid, code, json.dumps({"collector_number": cn, "lang": lang})),
        )
    for i, (sid, qty) in enumerate(inventories, 1):
        con.execute("insert into inventories values (?,?,?)", (i, sid, qty))
    con.commit()
    con.close()
    return str(path)


class FakeSmc:
    """Stands in for the ShowMyCards client, recording everything it is asked to do.

    `responses` maps (method, path) to a value or a callable(body); `paged` maps a
    path to the list a `.paged()` walk should return.
    """

    def __init__(self, responses=None, paged=None):
        self.responses = dict(responses or {})
        self.paged_data = dict(paged or {})
        self.calls = []

    def __call__(self, path, method="GET", body=None):
        path = path.replace("/?", "?", 1)
        if path.endswith("/"):
            path = path[:-1]
        self.calls.append((method, path, body))
        reply = self.responses.get((method, path))
        return reply(body) if callable(reply) else reply

    def paged(self, path):
        self.calls.append(("GET_PAGED", path, None))
        return list(self.paged_data.get(path, []))

    @property
    def writes(self):
        """Every call that could change data. The assertion dry-run tests make."""
        return [c for c in self.calls if c[0] in ("POST", "PUT", "DELETE")]


def cfg_for(tmp_path, db, **kw):
    return mox.Config(
        users=("nSimon",),
        collection_user="nSimon",
        db=db,
        state_dir=str(tmp_path),
        fetch_delay=0,
        **kw,
    )


def row(sid, *, set_code="abc", cn="1", lang="en", qty=1, binder="b1", finish="nonFoil"):
    """One Moxfield collection row, in Moxfield's shape."""
    return {
        "card": {"scryfall_id": sid, "set": set_code, "cn": cn, "name": f"card-{sid}"},
        "language": {"code": lang},
        "quantity": qty,
        "finish": finish,
        "tradeBinder": {"publicId": binder, "name": "Binder One"} if binder else None,
    }


STORAGE = {("GET", "/storage/with-counts"): [
    {"id": 10, "name": "Binder One", "storage_type": "Binder"},
]}


# ── Config ────────────────────────────────────────────────────────────────────


def test_both_destructive_switches_default_to_safe():
    # A Config built with no env at all must not be able to write or mass-delete.
    empty = mox.Config()
    assert empty.dry_run is True
    assert empty.force_prune is False
    from_empty_env = mox.Config.from_env({})
    assert from_empty_env.dry_run is True
    assert from_empty_env.force_prune is False


def test_dry_run_is_off_only_for_the_exact_string_zero():
    assert mox.Config.from_env({"DRY_RUN": "0"}).dry_run is False
    for raw in ("1", "", "false", "no", "0 ", "00"):
        assert mox.Config.from_env({"DRY_RUN": raw}).dry_run is True


def test_users_are_split_and_stripped():
    cfg = mox.Config.from_env({"MOXFIELD_USERS": " nSimon , Hexaphrodite ,, "})
    assert cfg.users == ("nSimon", "Hexaphrodite")


# ── the prune ceiling ─────────────────────────────────────────────────────────


def held(item_id, sid, qty=1, loc=10, treat="nonfoil"):
    return {
        "id": item_id,
        "scryfall_id": sid,
        "quantity": qty,
        "treatment": treat,
        "storage_location_id": loc,
        "oracle_id": f"o-{sid}",
    }


def test_mirror_refuses_when_the_diff_would_delete_most_of_the_inventory(tmp_path, capsys):
    # One card on Moxfield, ten unrelated cards in ShowMyCards: the diff says
    # "delete ten". A renamed binder or a partial API response looks exactly like
    # this, and there is no undo.
    db = make_db(tmp_path, [("s1", "o-s1", "abc", "1", "en")])
    smc = FakeSmc(
        responses=STORAGE,
        paged={"/inventory/": [held(i, f"other{i}") for i in range(1, 11)]},
    )
    cfg = cfg_for(tmp_path, db, dry_run=False)
    con = mox.open_db(cfg)
    try:
        assert mox.mirror_inventory(cfg, smc, con, [row("s1")]) is None
    finally:
        con.close()
    assert smc.writes == []
    assert "REFUSING" in capsys.readouterr().out


def test_force_prune_overrides_the_ceiling(tmp_path):
    db = make_db(tmp_path, [("s1", "o-s1", "abc", "1", "en")])
    smc = FakeSmc(
        responses=STORAGE,
        paged={"/inventory/": [held(i, f"other{i}") for i in range(1, 11)]},
    )
    cfg = cfg_for(tmp_path, db, dry_run=False, force_prune=True)
    con = mox.open_db(cfg)
    try:
        result = mox.mirror_inventory(cfg, smc, con, [row("s1")])
    finally:
        con.close()
    assert result == (1, 0, 10)
    deletes = [c for c in smc.writes if c[0] == "DELETE"]
    assert deletes == [("DELETE", "/inventory/batch", {"ids": list(range(1, 11))})]


def test_a_prune_under_the_ceiling_proceeds(tmp_path):
    # 1 of 10 cards removed = 10%, well under the 30% ceiling.
    db = make_db(tmp_path, [(f"s{i}", f"o-s{i}", "abc", str(i), "en") for i in range(1, 11)])
    current = [held(i, f"s{i}") for i in range(1, 11)]
    smc = FakeSmc(responses=STORAGE, paged={"/inventory/": current})
    cfg = cfg_for(tmp_path, db, dry_run=False)
    rows = [row(f"s{i}", cn=str(i)) for i in range(1, 10)]  # s10 gone
    con = mox.open_db(cfg)
    try:
        assert mox.mirror_inventory(cfg, smc, con, rows) == (0, 0, 1)
    finally:
        con.close()
    assert [c for c in smc.writes if c[0] == "DELETE"] == [
        ("DELETE", "/inventory/batch", {"ids": [10]})
    ]


def test_an_empty_inventory_is_never_blocked_by_the_ceiling(tmp_path):
    # total_now == 0: the guard must not divide the first-ever run into a refusal.
    db = make_db(tmp_path, [("s1", "o-s1", "abc", "1", "en")])
    smc = FakeSmc(responses=STORAGE, paged={"/inventory/": []})
    cfg = cfg_for(tmp_path, db, dry_run=False)
    con = mox.open_db(cfg)
    try:
        assert mox.mirror_inventory(cfg, smc, con, [row("s1")]) == (1, 0, 0)
    finally:
        con.close()


# ── dry run means dry ─────────────────────────────────────────────────────────


def test_dry_run_computes_the_diff_and_writes_nothing(tmp_path):
    db = make_db(tmp_path, [("s1", "o-s1", "abc", "1", "en"), ("s2", "o-s2", "abc", "2", "en")])
    smc = FakeSmc(responses=STORAGE, paged={"/inventory/": [held(1, "s2", qty=3)]})
    cfg = cfg_for(tmp_path, db)  # dry_run defaults True
    con = mox.open_db(cfg)
    try:
        added, updated, removed = mox.mirror_inventory(
            cfg, smc, con, [row("s1"), row("s2", cn="2", qty=5)]
        )
    finally:
        con.close()
    assert (added, updated, removed) == (1, 1, 0)
    assert smc.writes == []


def test_dry_run_does_not_create_storage_locations(tmp_path):
    smc = FakeSmc(responses={("GET", "/storage/with-counts"): []})
    cfg = cfg_for(tmp_path, "unused")
    assert mox.sync_storage_locations(cfg, smc, [row("s1")]) == {}
    assert smc.writes == []
    # …and nothing is persisted, so the real run still adopts cleanly.
    assert not (tmp_path / "binders.json").exists()


def test_dry_run_reconcile_writes_nothing(tmp_path):
    smc = FakeSmc(paged={"/lists/7/items": [
        {"id": 1, "scryfall_id": "s1", "treatment": "nonfoil",
         "desired_quantity": 1, "collected_quantity": 0},
    ]})
    cfg = cfg_for(tmp_path, "unused")
    counts = mox.reconcile(cfg, smc, 7, {("s1", "nonfoil"): 4}, {"s1": "o1"}, {("s1", "nonfoil"): 2})
    assert counts == (0, 1, 0)
    assert smc.writes == []


# ── language: the remap that makes a second run a no-op ───────────────────────

FR_DB = [
    ("en-id", "oracle-1", "abc", "42", "en"),
    ("fr-id", "oracle-1", "abc", "42", "fr"),
]


def test_a_french_row_resolves_to_the_french_printing(tmp_path):
    # Moxfield reports the ENGLISH id plus language=fr. Mirroring that id verbatim
    # deletes the French card and re-adds the English one, every single run.
    db = make_db(tmp_path, FR_DB)
    cfg = cfg_for(tmp_path, db)
    con = mox.open_db(cfg)
    try:
        rows = [row("en-id", set_code="abc", cn="42", lang="fr")]
        known = mox.oracle_ids(con, {"en-id"})
        idx = mox.resolve_printings(con, rows, known)
        assert idx[("abc", "42", "fr")] == "fr-id"
        smc = FakeSmc(responses=STORAGE)
        wanted, stats = mox.build_wanted_inventory(cfg, smc, con, rows)
    finally:
        con.close()
    assert list(wanted) == [("fr-id", "nonfoil", 10)]
    assert stats["remapped"] == 1


def test_a_second_consecutive_run_is_a_no_op(tmp_path):
    # The regression that matters: with the row already stored under the French
    # printing, the mirror must plan nothing at all.
    db = make_db(tmp_path, FR_DB)
    smc = FakeSmc(
        responses=STORAGE,
        paged={"/inventory/": [held(1, "fr-id", qty=1, loc=10)]},
    )
    cfg = cfg_for(tmp_path, db, dry_run=False)
    con = mox.open_db(cfg)
    try:
        result = mox.mirror_inventory(
            cfg, smc, con, [row("en-id", set_code="abc", cn="42", lang="fr")]
        )
    finally:
        con.close()
    assert result == (0, 0, 0)
    assert smc.writes == []


def test_english_rows_keep_moxfields_own_id(tmp_path):
    db = make_db(tmp_path, FR_DB)
    cfg = cfg_for(tmp_path, db)
    con = mox.open_db(cfg)
    try:
        smc = FakeSmc(responses=STORAGE)
        wanted, stats = mox.build_wanted_inventory(
            cfg, smc, con, [row("en-id", set_code="abc", cn="42", lang="en")]
        )
    finally:
        con.close()
    assert list(wanted) == [("en-id", "nonfoil", 10)]
    assert stats["remapped"] == 0


def test_collector_numbers_differing_only_in_leading_zeros_still_match():
    assert mox._cn("042") == mox._cn("42") == "42"
    assert mox._cn("12a") == "12a"
    assert mox._cn("0") == "0"  # never normalised away entirely
    assert mox._cn(None) == ""


# ── build_wanted_inventory ────────────────────────────────────────────────────


def test_en_and_fr_of_one_printing_in_one_binder_collapse_by_summing(tmp_path):
    # ShowMyCards' inventory has no language column, so two Moxfield rows are one row.
    db = make_db(tmp_path, [("s1", "o1", "abc", "1", "en")])
    cfg = cfg_for(tmp_path, db)
    con = mox.open_db(cfg)
    try:
        smc = FakeSmc(responses=STORAGE)
        wanted, _ = mox.build_wanted_inventory(
            cfg, smc, con, [row("s1", qty=2), row("s1", qty=3)]
        )
    finally:
        con.close()
    assert wanted == {("s1", "nonfoil", 10): 5}


def test_a_card_outside_the_local_catalogue_is_skipped_not_guessed(tmp_path):
    db = make_db(tmp_path, [("s1", "o1", "abc", "1", "en")])
    cfg = cfg_for(tmp_path, db)
    con = mox.open_db(cfg)
    try:
        smc = FakeSmc(responses=STORAGE)
        wanted, stats = mox.build_wanted_inventory(
            cfg, smc, con, [row("s1"), row("japanese-only", cn="9", lang="ja")]
        )
    finally:
        con.close()
    assert list(wanted) == [("s1", "nonfoil", 10)]
    assert stats["unresolved"] == 1


def test_an_unknown_finish_falls_back_to_nonfoil_and_is_counted(tmp_path):
    db = make_db(tmp_path, [("s1", "o1", "abc", "1", "en")])
    cfg = cfg_for(tmp_path, db)
    con = mox.open_db(cfg)
    try:
        smc = FakeSmc(responses=STORAGE)
        wanted, stats = mox.build_wanted_inventory(
            cfg, smc, con, [row("s1", finish="galaxyFoil")]
        )
    finally:
        con.close()
    assert list(wanted) == [("s1", "nonfoil", 10)]
    assert stats["bad_finish"] == 1


def test_a_card_in_no_binder_is_left_unassigned_and_counted(tmp_path):
    db = make_db(tmp_path, [("s1", "o1", "abc", "1", "en")])
    cfg = cfg_for(tmp_path, db)
    con = mox.open_db(cfg)
    try:
        smc = FakeSmc(responses=STORAGE)
        wanted, stats = mox.build_wanted_inventory(cfg, smc, con, [row("s1", binder=None)])
    finally:
        con.close()
    assert wanted == {("s1", "nonfoil", None): 1}
    assert stats["no_binder"] == 1


# ── mirror_inventory bookkeeping ──────────────────────────────────────────────


def test_an_update_resends_the_whole_row(tmp_path):
    # ShowMyCards writes non-pointer fields unconditionally, so a partial PUT is how
    # you silently blank storage_location_id.
    db = make_db(tmp_path, [("s1", "o-s1", "abc", "1", "en")])
    smc = FakeSmc(responses=STORAGE, paged={"/inventory/": [held(1, "s1", qty=1)]})
    cfg = cfg_for(tmp_path, db, dry_run=False)
    con = mox.open_db(cfg)
    try:
        mox.mirror_inventory(cfg, smc, con, [row("s1", qty=4)])
    finally:
        con.close()
    put = next(c for c in smc.writes if c[0] == "PUT")
    assert put[1] == "/inventory/1"
    assert put[2] == {
        "scryfall_id": "s1",
        "oracle_id": "o-s1",
        "treatment": "nonfoil",
        "quantity": 4,
        "storage_location_id": 10,
    }


def test_duplicate_rows_for_one_key_keep_the_first_and_drop_the_rest(tmp_path):
    db = make_db(tmp_path, [("s1", "o-s1", "abc", "1", "en")])
    smc = FakeSmc(
        responses=STORAGE,
        paged={"/inventory/": [held(1, "s1", qty=1), held(2, "s1", qty=1), held(3, "s1", qty=1)]},
    )
    cfg = cfg_for(tmp_path, db, dry_run=False, force_prune=True)
    con = mox.open_db(cfg)
    try:
        assert mox.mirror_inventory(cfg, smc, con, [row("s1", qty=1)]) == (0, 0, 2)
    finally:
        con.close()
    assert [c for c in smc.writes if c[0] == "DELETE"] == [
        ("DELETE", "/inventory/batch", {"ids": [2, 3]})
    ]


def test_a_card_with_no_local_oracle_id_is_skipped_on_post(tmp_path):
    # oracle_id is mandatory on POST; a row without one cannot be created.
    db = make_db(tmp_path, [("s1", None, "abc", "1", "en")])
    smc = FakeSmc(responses=STORAGE, paged={"/inventory/": []})
    cfg = cfg_for(tmp_path, db, dry_run=False)
    con = mox.open_db(cfg)
    try:
        assert mox.mirror_inventory(cfg, smc, con, [row("s1")]) == (0, 0, 0)
    finally:
        con.close()
    assert smc.writes == []


# ── storage locations ─────────────────────────────────────────────────────────


def test_a_binder_renamed_on_moxfield_renames_the_location(tmp_path):
    smc = FakeSmc(responses={
        ("GET", "/storage/with-counts"): [
            {"id": 10, "name": "Magic Big Box", "storage_type": "Box"}
        ],
        ("PUT", "/storage/10"): lambda body: body,
    })
    (tmp_path / "binders.json").write_text(json.dumps({"b1": 10}))
    cfg = cfg_for(tmp_path, "unused", dry_run=False)
    rows = [row("s1", binder="b1")]
    rows[0]["tradeBinder"]["name"] = "Big Box"
    assert mox.sync_storage_locations(cfg, smc, rows) == {"b1": 10}
    assert smc.writes == [
        ("PUT", "/storage/10", {"name": "Big Box", "storage_type": "Box"})
    ]


def test_a_cold_state_file_adopts_existing_locations_by_name(tmp_path):
    # Otherwise a rebuilt state duplicates every binder.
    smc = FakeSmc(responses=STORAGE)
    cfg = cfg_for(tmp_path, "unused", dry_run=False)
    assert mox.sync_storage_locations(cfg, smc, [row("s1")]) == {"b1": 10}
    assert smc.writes == []
    assert json.loads((tmp_path / "binders.json").read_text()) == {"b1": 10}


def test_a_corrupt_state_file_falls_back_to_name_adoption(tmp_path, capsys):
    (tmp_path / "binders.json").write_text("{not json")
    smc = FakeSmc(responses=STORAGE)
    cfg = cfg_for(tmp_path, "unused", dry_run=False)
    assert mox.sync_storage_locations(cfg, smc, [row("s1")]) == {"b1": 10}
    assert "binders.json unreadable" in capsys.readouterr().out


def test_an_unseen_binder_is_created_with_a_type_inferred_from_its_name(tmp_path):
    smc = FakeSmc(responses={
        ("GET", "/storage/with-counts"): [],
        ("POST", "/storage"): lambda body: {"id": 99, **body},
    })
    cfg = cfg_for(tmp_path, "unused", dry_run=False)
    rows = [row("s1", binder="b9")]
    rows[0]["tradeBinder"]["name"] = "Green Deck Box"
    assert mox.sync_storage_locations(cfg, smc, rows) == {"b9": 99}
    assert smc.writes == [
        ("POST", "/storage", {"name": "Green Deck Box", "storage_type": "Box"})
    ]


@pytest.mark.parametrize(
    ("name", "expected"),
    [("Big Box", "Box"), ("Green Deck Box", "Box"), ("BOOK - Red Dragon", "Binder"),
     ("EDH - Errant", "Binder"), (None, "Binder")],
)
def test_storage_type_is_inferred_from_the_name(name, expected):
    assert mox.infer_storage_type(name) == expected


# ── ownership arithmetic ──────────────────────────────────────────────────────


def test_ownership_collapses_printing_and_finish(tmp_path):
    # Keying on the printing is what made a deck report 54/100 with every card in a
    # binder.
    db = make_db(
        tmp_path,
        [("en-id", "oracle-1", "abc", "42", "en"), ("fr-id", "oracle-1", "abc", "42", "fr")],
        inventories=[("en-id", 2), ("fr-id", 3)],
    )
    con = sqlite3.connect(db)
    try:
        assert mox.owned_by_oracle(con) == {"oracle-1": 5}
    finally:
        con.close()


def test_two_printings_of_one_card_share_a_single_ownership_pool():
    # 8 Forests wanted across two printings with 5 owned is 5 collected, not 5 + 5.
    wanted = {("print-a", "nonfoil"): 4, ("print-b", "nonfoil"): 4}
    oids = {"print-a": "forest", "print-b": "forest"}
    collected = mox.allocate_collected(wanted, oids, {"forest": 5})
    assert sum(collected.values()) == 5
    assert collected == {("print-a", "nonfoil"): 4, ("print-b", "nonfoil"): 1}


def test_allocation_is_deterministic_regardless_of_dict_order():
    oids = {"a": "o", "b": "o"}
    first = mox.allocate_collected({("a", "nonfoil"): 2, ("b", "nonfoil"): 2}, oids, {"o": 3})
    second = mox.allocate_collected({("b", "nonfoil"): 2, ("a", "nonfoil"): 2}, oids, {"o": 3})
    assert first == second


def test_a_card_outside_the_catalogue_gets_no_allocation():
    assert mox.allocate_collected({("x", "nonfoil"): 1}, {}, {"o": 9}) == {}


# ── deck parsing ──────────────────────────────────────────────────────────────


def deck_with(boards):
    return {"name": "Deck", "boards": boards}


def test_only_the_deck_proper_is_synced_and_the_rest_is_reported():
    deck = deck_with({
        "commanders": {"count": 1, "cards": {"a": {"quantity": 1, "card": {"scryfall_id": "c1"}}}},
        "mainboard": {"count": 2, "cards": {"b": {"quantity": 2, "card": {"scryfall_id": "m1"}}}},
        "sideboard": {"count": 7, "cards": {"c": {"quantity": 7, "card": {"scryfall_id": "s1"}}}},
        "maybeboard": {"count": 0, "cards": {}},
    })
    wanted, excluded = mox.parse_deck(deck)
    assert wanted == {("c1", "nonfoil"): 1, ("m1", "nonfoil"): 2}
    assert excluded == {"sideboard": 7}  # empty boards are not reported


def test_foil_entries_get_their_own_treatment_and_sum_separately():
    deck = deck_with({"mainboard": {"count": 3, "cards": {
        "a": {"quantity": 1, "card": {"scryfall_id": "x"}, "isFoil": True},
        "b": {"quantity": 2, "card": {"scryfall_id": "x"}},
        "c": {"quantity": 1, "card": {"scryfall_id": "x"}, "isFoil": True},
    }}})
    wanted, _ = mox.parse_deck(deck)
    assert wanted == {("x", "foil"): 2, ("x", "nonfoil"): 2}


def test_entries_without_a_scryfall_id_are_dropped():
    deck = deck_with({"mainboard": {"count": 1, "cards": {"a": {"quantity": 1, "card": {}}}}})
    assert mox.parse_deck(deck) == ({}, {})


def test_the_fingerprint_changes_when_the_collection_moves_underneath_a_deck():
    # Without the inventory hash in here, ownership counts freeze at whatever they
    # were when the deck itself last changed.
    wanted = {("s1", "nonfoil"): 1}
    a = mox.deck_fingerprint(wanted, "Deck", "inv-1")
    b = mox.deck_fingerprint(wanted, "Deck", "inv-2")
    assert a != b
    assert a == mox.deck_fingerprint(wanted, "Deck", "inv-1")


def test_the_fingerprint_ignores_dict_ordering():
    left = mox.deck_fingerprint({("a", "nonfoil"): 1, ("b", "foil"): 2}, "D", "i")
    right = mox.deck_fingerprint({("b", "foil"): 2, ("a", "nonfoil"): 1}, "D", "i")
    assert left == right


# ── list matching + reconciliation ────────────────────────────────────────────


def test_the_moxfield_url_in_the_description_wins_over_the_name():
    lists = [
        {"id": 1, "name": "Deck", "description": ""},
        {"id": 2, "name": "renamed on showmycards", "description": "…/decks/PUB123"},
    ]
    assert mox.find_list(lists, "PUB123", "Deck")["id"] == 2


def test_a_hand_made_list_is_adopted_by_name():
    lists = [{"id": 3, "name": " Deck ", "description": ""}]
    assert mox.find_list(lists, "PUB123", "Deck")["id"] == 3
    assert mox.find_list(lists, "PUB123", "Other") is None


def test_new_items_get_a_follow_up_put_to_carry_ownership(tmp_path):
    # collected_quantity is forced to 0 on create.
    created = {"id": 55, "scryfall_id": "s1", "treatment": "nonfoil"}
    smc = FakeSmc(paged={"/lists/7/items": []})
    calls = {"n": 0}

    def paged(path):
        # Empty before the batch POST, populated after — as the real API behaves.
        calls["n"] += 1
        smc.calls.append(("GET_PAGED", path, None))
        return [] if calls["n"] == 1 else [created]

    smc.paged = paged
    cfg = cfg_for(tmp_path, "unused", dry_run=False)
    counts = mox.reconcile(
        cfg, smc, 7, {("s1", "nonfoil"): 3}, {"s1": "o1"}, {("s1", "nonfoil"): 2}
    )
    assert counts == (1, 0, 0)
    assert smc.writes == [
        ("POST", "/lists/7/items/batch", {"items": [
            {"scryfall_id": "s1", "oracle_id": "o1", "treatment": "nonfoil",
             "desired_quantity": 3},
        ]}),
        ("PUT", "/lists/7/items/55", {"desired_quantity": 3, "collected_quantity": 2}),
    ]


def test_an_item_whose_ownership_changed_is_updated_even_when_desired_did_not(tmp_path):
    smc = FakeSmc(paged={"/lists/7/items": [
        {"id": 1, "scryfall_id": "s1", "treatment": "nonfoil",
         "desired_quantity": 4, "collected_quantity": 1},
    ]})
    cfg = cfg_for(tmp_path, "unused", dry_run=False)
    assert mox.reconcile(
        cfg, smc, 7, {("s1", "nonfoil"): 4}, {"s1": "o1"}, {("s1", "nonfoil"): 3}
    ) == (0, 1, 0)
    assert smc.writes == [
        ("PUT", "/lists/7/items/1", {"desired_quantity": 4, "collected_quantity": 3})
    ]


def test_an_unchanged_item_is_left_alone(tmp_path):
    smc = FakeSmc(paged={"/lists/7/items": [
        {"id": 1, "scryfall_id": "s1", "treatment": "nonfoil",
         "desired_quantity": 4, "collected_quantity": 3},
    ]})
    cfg = cfg_for(tmp_path, "unused", dry_run=False)
    assert mox.reconcile(
        cfg, smc, 7, {("s1", "nonfoil"): 4}, {"s1": "o1"}, {("s1", "nonfoil"): 3}
    ) == (0, 0, 0)
    assert smc.writes == []


def test_items_no_longer_in_the_deck_are_removed(tmp_path):
    smc = FakeSmc(paged={"/lists/7/items": [
        {"id": 9, "scryfall_id": "gone", "treatment": "nonfoil",
         "desired_quantity": 1, "collected_quantity": 0},
    ]})
    cfg = cfg_for(tmp_path, "unused", dry_run=False)
    assert mox.reconcile(cfg, smc, 7, {}, {}, {}) == (0, 0, 1)
    assert smc.writes == [("DELETE", "/lists/7/items/9", None)]


# ── the Moxfield client ───────────────────────────────────────────────────────


def test_a_private_collection_fails_loudly():
    # Reading it as "the user owns nothing" would delete the whole inventory.
    op = FakeOpener([json_reply({"collectionVisibility": "private", "collectionPublicId": "c1"})])
    client = mox.Moxfield("ua", opener=op, sleep=lambda _: None)
    with pytest.raises(RuntimeError, match="not publicly readable"):
        client.collection("nSimon")


def test_a_truncated_collection_response_fails_loudly():
    op = FakeOpener([
        json_reply({"collectionVisibility": "public", "collectionPublicId": "c1"}),
        json_reply({"data": [row("s1")], "totalResults": 99, "totalPages": 1}),
    ])
    client = mox.Moxfield("ua", opener=op, sleep=lambda _: None)
    with pytest.raises(RuntimeError, match="truncated"):
        client.collection("nSimon")


def test_an_empty_collection_fails_loudly():
    op = FakeOpener([
        json_reply({"collectionVisibility": "public", "collectionPublicId": "c1"}),
        json_reply({"data": [], "totalResults": 0, "totalPages": 1}),
    ])
    client = mox.Moxfield("ua", opener=op, sleep=lambda _: None)
    with pytest.raises(RuntimeError, match="refusing to prune everything"):
        client.collection("nSimon")


def test_a_paginated_collection_is_concatenated():
    op = FakeOpener([
        json_reply({"collectionVisibility": "public", "collectionPublicId": "c1"}),
        json_reply({"data": [row("s1")], "totalPages": 2, "totalResults": 2}),
        json_reply({"data": [row("s2")], "totalPages": 2, "totalResults": 2}),
    ])
    client = mox.Moxfield("ua", opener=op, sleep=lambda _: None)
    assert len(client.collection("nSimon")) == 2


def test_deck_search_asks_for_illegal_decks_too():
    # Without showIllegal, Moxfield hides mid-build decks — exactly the ones worth
    # syncing, since the list IS the shopping list.
    op = FakeOpener([json_reply({"data": [], "totalPages": 1})])
    client = mox.Moxfield("ua", opener=op, sleep=lambda _: None)
    client.discover_decks(["nSimon"])
    assert "showIllegal=true" in op.last.full_url


def test_decks_reachable_through_two_users_are_deduped():
    deck = {"publicId": "P1", "name": "Shared", "createdByUser": {"userName": "other"}}
    op = FakeOpener([
        json_reply({"data": [deck], "totalPages": 1}),
        json_reply({"data": [deck], "totalPages": 1}),
    ])
    client = mox.Moxfield("ua", opener=op, sleep=lambda _: None)
    assert client.discover_decks(["nSimon", "Hexaphrodite"]) == [("P1", "Shared", "other")]


def test_the_user_agent_identifies_the_project():
    op = FakeOpener([json_reply({"data": [], "totalPages": 1})])
    mox.Moxfield("nic-os-moxfield-sync/1.0", opener=op, sleep=lambda _: None).discover_decks(["u"])
    assert op.last.get_header("User-agent") == "nic-os-moxfield-sync/1.0"


def test_a_rate_limited_fetch_is_retried_with_backoff():
    waits = []
    calls = {"n": 0}

    def opener(req, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            raise urllib.error.HTTPError(req.full_url, 429, "slow down", {}, None)
        return json_reply({"ok": True})()

    client = mox.Moxfield("ua", opener=opener, sleep=waits.append)
    assert client.get("http://x", "label") == {"ok": True}
    assert waits == [5]


def test_a_permanent_error_is_not_retried_forever():
    def opener(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 404, "gone", {}, None)

    client = mox.Moxfield("ua", opener=opener, sleep=lambda _: None)
    with pytest.raises(urllib.error.HTTPError):
        client.get("http://x", "label")


# ── the ShowMyCards client ────────────────────────────────────────────────────


def test_trailing_slashes_are_normalised_away_to_save_a_redirect():
    op = FakeOpener([json_reply({})])
    smc = mox.Smc("http://smc/api", opener=op)
    smc("/inventory/")
    assert op.last.full_url == "http://smc/api/inventory"
    smc("/inventory/?page=1")
    assert op.last.full_url == "http://smc/api/inventory?page=1"


def test_paged_walks_every_page():
    op = FakeOpener([
        json_reply({"data": [1], "total_pages": 3}),
        json_reply({"data": [2], "total_pages": 3}),
        json_reply({"data": [3], "total_pages": 3}),
    ])
    assert mox.Smc("http://smc/api", opener=op).paged("/inventory/") == [1, 2, 3]
    assert "page=3" in op.last.full_url


def test_a_post_carries_a_json_body_and_content_type():
    op = FakeOpener([json_reply({"id": 1})])
    mox.Smc("http://smc/api", opener=op)("/storage", "POST", {"name": "x"})
    assert json.loads(op.last.data.decode()) == {"name": "x"}
    assert op.last.get_header("Content-type") == "application/json"


def test_delete_batches_are_capped_and_fall_back_to_per_id(capsys):
    smc = FakeSmc(responses={("DELETE", "/inventory/batch"): None})
    mox.delete_inventory(smc, list(range(1, 1201)))
    batches = [c for c in smc.calls if c[1] == "/inventory/batch"]
    assert [len(c[2]["ids"]) for c in batches] == [500, 500, 200]

    def refuse(path, method="GET", body=None):
        if path == "/inventory/batch":
            raise urllib.error.HTTPError(path, 405, "nope", {}, None)
        refuse.seen.append(path)

    refuse.seen = []
    mox.delete_inventory(refuse, [7, 8])
    assert refuse.seen == ["/inventory/7", "/inventory/8"]
    assert "falling back to per-id" in capsys.readouterr().out


# ── main / sync_collection ────────────────────────────────────────────────────


def test_main_does_nothing_without_configured_users(capsys):
    assert mox.main(env={}) == 0
    assert "nothing to do" in capsys.readouterr().out


def test_a_failed_collection_fetch_leaves_the_inventory_untouched(tmp_path, capsys):
    class Boom:
        sleep = staticmethod(lambda _: None)

        def collection(self, user):
            raise urllib.error.URLError("moxfield down")

    smc = FakeSmc()
    cfg = cfg_for(tmp_path, "unused", dry_run=False)
    assert mox.sync_collection(cfg, smc, Boom()) is False
    assert smc.writes == []
    assert "inventory untouched" in capsys.readouterr().out


def test_a_failed_discovery_aborts_the_whole_run(tmp_path, capsys):
    # A partial deck list reads as "these decks were deleted" and would empty them.
    db = make_db(tmp_path, [("s1", "o1", "abc", "1", "en")])

    class Boom:
        sleep = staticmethod(lambda _: None)

        def discover_decks(self, users):
            raise urllib.error.URLError("search down")

    smc = FakeSmc(responses={("GET", "/lists"): []})
    cfg = cfg_for(tmp_path, db, dry_run=False)
    totals, ok = mox.sync_decks(cfg, smc, Boom())
    assert ok is False
    assert smc.writes == []
    assert "aborting without changes" in capsys.readouterr().out


def test_an_unchanged_deck_costs_no_writes(tmp_path):
    db = make_db(tmp_path, [("s1", "o1", "abc", "1", "en")], inventories=[("s1", 1)])
    cfg = cfg_for(tmp_path, db, dry_run=False)
    wanted = {("s1", "nonfoil"): 1}
    fp = mox.deck_fingerprint(wanted, "Deck", mox.inventory_fingerprint({"o1": 1}))
    (tmp_path / "P1.hash").write_text(fp)

    class Fake:
        sleep = staticmethod(lambda _: None)

        def discover_decks(self, users):
            return [("P1", "Deck", "nSimon")]

        def deck(self, pid):
            return {"name": "Deck", "boards": {"mainboard": {
                "count": 1, "cards": {"a": {"quantity": 1, "card": {"scryfall_id": "s1"}}}}}}

    smc = FakeSmc(responses={("GET", "/lists"): [
        {"id": 1, "name": "Deck", "description": "P1"}
    ]})
    totals, ok = mox.sync_decks(cfg, smc, Fake())
    assert ok is True
    assert totals["unchanged"] == 1
    assert smc.writes == []
