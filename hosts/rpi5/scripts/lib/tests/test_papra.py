"""The three Papra units.

tag_sweep and proton_poll were previously unimportable off-host (SQLite opened and
`os.environ[...]` read at module level). These tests prove importing them does
nothing, then cover the sweeper's EX_TEMPFAIL contract and date backfill, the
archive reconciler, and the drop-zone's filename handling.
"""

import base64
import email
import json
import os
import sqlite3
import urllib.error

import pytest
from conftest import FakeOpener, json_reply

from nicos_scripts.papra import nc_sync, proton_poll, tag_sweep

MS_2018 = 1530489600000  # 2018-07-02T00:00Z

# ── importability ─────────────────────────────────────────────────────────────


def test_the_modules_have_no_import_time_side_effects():
    # A Config built from an empty env must not raise, open a socket, or touch disk.
    assert tag_sweep.Config.from_env({}).db == "/var/lib/papra/db.sqlite"
    assert nc_sync.Config.from_env({}).apply is False
    assert proton_poll.Config.from_env({}).dest == ""


# ── fixture ───────────────────────────────────────────────────────────────────


def papra_db(tmp_path, docs, tags=(), doc_tags=(), dates=None, keys=None):
    """docs: (id, org, name, content, deleted_at). tags: (id, org, name, norm)."""
    path = tmp_path / "papra.sqlite"
    con = sqlite3.connect(str(path))
    con.execute(
        "create table documents (id text primary key, organization_id text, name text,"
        " original_name text, content text, deleted_at integer,"
        " is_deleted integer default 0, original_storage_key text, document_date integer)"
    )
    con.execute(
        "create table tags (id text primary key, created_at integer, updated_at integer,"
        " organization_id text, name text, color text, description text,"
        " normalized_name text)"
    )
    con.execute(
        "create table documents_tags (document_id text, tag_id text,"
        " primary key (document_id, tag_id))"
    )
    for doc_id, org, name, content, deleted in docs:
        con.execute(
            "insert into documents (id, organization_id, name, original_name, content,"
            " deleted_at, original_storage_key, document_date) values (?,?,?,?,?,?,?,?)",
            (doc_id, org, name, name, content, deleted,
             (keys or {}).get(doc_id), (dates or {}).get(doc_id)),
        )
    for tid, org, name, norm in tags:
        con.execute(
            "insert into tags values (?,?,?,?,?,?,?,?)",
            (tid, 0, 0, org, name, "#CCCCCC", None, norm),
        )
    for doc_id, tid in doc_tags:
        con.execute("insert into documents_tags values (?,?)", (doc_id, tid))
    con.commit()
    return path, con


def date_of(con, doc_id):
    return con.execute("select document_date from documents where id=?", (doc_id,)).fetchone()[0]


# ── tag_sweep ─────────────────────────────────────────────────────────────────


def test_only_untagged_documents_are_swept(tmp_path):
    path, con = papra_db(
        tmp_path,
        docs=[("d1", "org", "untagged.pdf", "aaa", None),
              ("d2", "org", "tagged.pdf", "bbb", None),
              ("d3", "org", "deleted.pdf", "ccc", 1700000000)],
        tags=[("t1", "org", "Facture", "facture")],
        doc_tags=[("d2", "t1")],
    )
    cfg = tag_sweep.Config(db=str(path))
    asked = []

    def ask(name, content, tagnames, sysp):
        asked.append(name)
        return {"existingTags": ["Facture"], "newTags": []}

    assert tag_sweep.sweep(cfg, con, ask_fn=ask, now=1) == 1
    assert asked == ["untagged.pdf"]
    assert con.execute(
        "select tag_id from documents_tags where document_id='d1'"
    ).fetchall() == [("t1",)]
    con.close()


def test_the_smallest_documents_are_swept_first(tmp_path):
    # Cheapest prompts first, so a gate that dies mid-sweep has cleared the most.
    path, con = papra_db(tmp_path, docs=[
        ("big", "org", "big.pdf", "x" * 100, None),
        ("small", "org", "small.pdf", "x", None),
    ])
    order = []
    tag_sweep.sweep(
        tag_sweep.Config(db=str(path)), con,
        ask_fn=lambda name, *a: (order.append(name), {"existingTags": [], "newTags": []})[1],
        now=1,
    )
    assert order == ["small.pdf", "big.pdf"]
    con.close()


def test_a_new_tag_is_created_once_and_reused_for_later_documents(tmp_path):
    path, con = papra_db(tmp_path, docs=[
        ("d1", "org", "a.pdf", "x", None),
        ("d2", "org", "b.pdf", "xx", None),
    ])
    ids = iter("abcdefghijklmnopqrstuvwxyz0123456789" * 5)
    tag_sweep.sweep(
        tag_sweep.Config(db=str(path)), con,
        ask_fn=lambda *a: {"existingTags": [], "newTags": [{"name": "Assurance"}]},
        now=1234,
        rand=lambda alphabet: next(ids),
    )
    rows = con.execute("select id, name, normalized_name, created_at from tags").fetchall()
    assert len(rows) == 1
    assert rows[0][1:] == ("Assurance", "assurance", 1234)
    assert rows[0][0].startswith("tag_")
    # Both documents point at that single tag.
    assert con.execute("select count(*) from documents_tags").fetchone()[0] == 2
    con.close()


def test_a_blank_new_tag_name_is_ignored(tmp_path):
    path, con = papra_db(tmp_path, docs=[("d1", "org", "a.pdf", "x", None)])
    tag_sweep.sweep(
        tag_sweep.Config(db=str(path)), con,
        ask_fn=lambda *a: {"existingTags": [], "newTags": [{"name": "  "}, {}]},
        now=1,
    )
    assert con.execute("select count(*) from tags").fetchone()[0] == 0
    con.close()


def test_a_hallucinated_existing_tag_is_dropped_not_created(tmp_path):
    path, con = papra_db(
        tmp_path,
        docs=[("d1", "org", "a.pdf", "x", None)],
        tags=[("t1", "org", "Facture", "facture")],
    )
    tag_sweep.sweep(
        tag_sweep.Config(db=str(path)), con,
        ask_fn=lambda *a: {"existingTags": ["Nope"], "newTags": []},
        now=1,
    )
    assert con.execute("select count(*) from documents_tags").fetchone()[0] == 0
    con.close()


def test_a_gate_failure_keeps_what_was_already_tagged_and_aborts(tmp_path):
    path, con = papra_db(tmp_path, docs=[
        ("d1", "org", "small.pdf", "x", None),
        ("d2", "org", "big.pdf", "x" * 50, None),
    ], tags=[("t1", "org", "Facture", "facture")])
    calls = {"n": 0}

    def flaky(name, content, tagnames, sysp):
        calls["n"] += 1
        if calls["n"] == 2:
            raise urllib.error.URLError("beast asleep")
        return {"existingTags": ["Facture"], "newTags": []}

    with pytest.raises(tag_sweep.GateUnreachable):
        tag_sweep.sweep(tag_sweep.Config(db=str(path)), con, ask_fn=flaky, now=1)
    # The first document's tags are committed; the second stays in the backlog.
    assert con.execute("select document_id from documents_tags").fetchall() == [("d1",)]
    con.close()


def test_main_returns_ex_tempfail_so_the_timer_retries(tmp_path, capsys):
    path, con = papra_db(tmp_path, docs=[("d1", "org", "a.pdf", "x", None)])
    cfg_env = {"PAPRA_DB": str(path), "PAPRA_GATE_URL": "http://127.0.0.1:1/nope"}
    # No gate listening on port 1 → the real ask() fails → EX_TEMPFAIL, not a crash.
    assert tag_sweep.main(env=cfg_env, con=con) == 75
    out = capsys.readouterr().out
    assert "ABORT" in out and "next run" in out
    assert tag_sweep.EX_TEMPFAIL == 75


def test_main_reports_the_swept_count(tmp_path, capsys):
    path, con = papra_db(tmp_path, docs=[])
    assert tag_sweep.main(env={"PAPRA_DB": str(path)}, con=con) == 0
    assert "DONE swept 0 untagged doc(s)" in capsys.readouterr().out


def test_the_schema_pins_existing_tags_to_an_enum():
    schema = tag_sweep.tag_schema(["Facture", "Assurance"])
    assert schema["properties"]["existingTags"]["items"]["enum"] == ["Facture", "Assurance"]
    assert schema["required"] == ["existingTags", "newTags", "documentDate"]


def test_the_prompt_is_capped_and_carries_the_existing_tags():
    cfg = tag_sweep.Config(cap=10)
    op = FakeOpener([json_reply(
        {"choices": [{"message": {"content": json.dumps({"existingTags": [], "newTags": []})}}]}
    )])
    tag_sweep.ask(cfg, "doc.pdf", "y" * 100, ["Facture"], "sys", opener=op)
    body = json.loads(op.last.data.decode())
    assert body["model"] == "qwen3-vl:8b"
    assert body["messages"][1]["content"].endswith("y" * 10)  # content truncated to cap
    assert "Facture" in tag_sweep.system_prompt(["Facture"])
    assert "max 6" in tag_sweep.system_prompt([])


def test_tag_ids_look_like_papras():
    assert tag_sweep.new_tag_id(lambda a: "a") == "tag_" + "a" * 24


# ── tag_sweep: document_date ──────────────────────────────────────────────────


def ymd(ts):
    import datetime
    return datetime.datetime.fromtimestamp(ts / 1000, datetime.UTC).date().isoformat()


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("2018-07-02_amazon_7.99EUR_408-2852872-2207567__419.pdf", "2018-07-02"),
        ("releve_20171009.pdf", "2017-10-09"),
        ("facture 04-06-2017.pdf", "2017-06-04"),
        ("free_201702.pdf", "2017-02-01"),
        ("Attestation LMDE 2018__4.pdf", "2018-01-01"),
        ("Passeport - 2028.08.07 - 2019.03.02.pdf", "2019-03-02"),  # expiry skipped
        ("releve 2017-13-45.pdf", "2017-01-01"),  # impossible month → bare year
    ],
)
def test_a_date_is_read_from_the_filename(name, expected):
    assert ymd(tag_sweep.filename_date(name, max_year=2026)) == expected


@pytest.mark.parametrize("name", [
    "attestation ameli 1 96 11 29 260 237 85.pdf",  # social-security number
    "Facture MyFirmin Partie 1 - Client__189.pdf",
    "scan 1985.pdf",  # before MIN_YEAR
    "contrat 2031.pdf",  # after max_year
    "",
])
def test_a_filename_without_a_plausible_date_yields_none(name):
    assert tag_sweep.filename_date(name, max_year=2026) is None


def test_a_gate_date_is_parsed_or_rejected():
    assert ymd(tag_sweep.parse_iso("2019-05-11", max_year=2026)) == "2019-05-11"
    assert tag_sweep.parse_iso("2019-02-30", max_year=2026) is None
    assert tag_sweep.parse_iso(None) is None
    assert tag_sweep.parse_iso("mai 2019") is None


def test_filename_dates_never_overwrite_an_existing_one(tmp_path):
    path, con = papra_db(tmp_path, docs=[
        ("d1", "org", "2018-07-02_a.pdf", "x", None),
        ("d2", "org", "2018-07-02_b.pdf", "x", None),
        ("d3", "org", "nodate.pdf", "x", None),
    ], dates={"d2": 42})
    assert tag_sweep.backfill_filename_dates(con) == (1, 1)
    assert ymd(date_of(con, "d1")) == "2018-07-02"
    assert date_of(con, "d2") == 42
    con.close()


def test_the_tag_call_also_dates_the_document(tmp_path):
    path, con = papra_db(tmp_path, docs=[("d1", "org", "a.pdf", "x", None)])
    tried = set()
    tag_sweep.sweep(
        tag_sweep.Config(db=str(path)), con, now=1, tried=tried,
        ask_fn=lambda *a: {"existingTags": [], "newTags": [], "documentDate": "2019-05-11"},
    )
    assert ymd(date_of(con, "d1")) == "2019-05-11"
    assert tried == {"d1"}
    con.close()


def test_the_gate_is_asked_once_per_undated_document(tmp_path):
    # A passport has no date at all; asking again every 15 min would hammer beast
    # and starve the documents behind it.
    path, con = papra_db(tmp_path, docs=[
        ("d1", "org", "passport.pdf", "x", None),
        ("d2", "org", "bill.pdf", "xx", None),
        ("d3", "org", "later.pdf", "xxx", None),
    ])
    cfg = tag_sweep.Config(db=str(path), date_batch=2)
    asked, tried = [], {"d1"}
    answers = {"bill.pdf": "2019-05-11", "later.pdf": None}

    def ask(name, content):
        asked.append(name)
        return {"documentDate": answers[name]}

    assert tag_sweep.backfill_gate_dates(cfg, con, tried, ask_fn=ask) == 1
    assert asked == ["bill.pdf", "later.pdf"]
    assert tried == {"d1", "d2", "d3"}
    assert tag_sweep.backfill_gate_dates(cfg, con, tried, ask_fn=ask) == 0
    assert asked == ["bill.pdf", "later.pdf"]
    con.close()


def test_the_gate_date_batch_is_capped(tmp_path):
    path, con = papra_db(tmp_path, docs=[(f"d{i}", "org", "x.pdf", "x", None) for i in range(5)])
    asked = []
    tag_sweep.backfill_gate_dates(
        tag_sweep.Config(db=str(path), date_batch=2), con, set(),
        ask_fn=lambda n, c: (asked.append(n), {"documentDate": None})[1])
    assert len(asked) == 2
    con.close()


def test_main_dates_from_filenames_even_when_the_gate_is_down(tmp_path, capsys):
    path, con = papra_db(
        tmp_path,
        docs=[("d1", "org", "2018-07-02_a.pdf", "x", None),
              ("d2", "org", "untagged.pdf", "x", None)],
    )
    state = tmp_path / "state"
    state.mkdir()

    def down(*a):
        raise urllib.error.URLError("beast asleep")

    rc = tag_sweep.main(env={"PAPRA_DB": str(path), "STATE_DIR": str(state)},
                        con=con, ask_fn=down, ask_date_fn=down)
    assert rc == 75
    check = sqlite3.connect(str(path))
    assert ymd(date_of(check, "d1")) == "2018-07-02"
    check.close()


def test_main_persists_which_documents_the_gate_was_asked_about(tmp_path):
    path, con = papra_db(tmp_path, docs=[("d1", "org", "nodate.pdf", "x", None)],
                         tags=[("t1", "org", "Passeport", "passeport")],
                         doc_tags=[("d1", "t1")])
    state = tmp_path / "state"
    state.mkdir()
    env = {"PAPRA_DB": str(path), "STATE_DIR": str(state)}
    assert tag_sweep.main(env=env, con=con,
                          ask_date_fn=lambda n, c: {"documentDate": None}) == 0
    assert json.loads((state / "date-asked.json").read_text()) == ["d1"]


# ── nc_sync ───────────────────────────────────────────────────────────────────


def test_the_type_tag_picks_the_folder_and_the_date_the_year():
    doc = {"tags": ["Abonnement", "Facture", "Facture télécom"], "date": MS_2018}
    assert nc_sync.classify(doc) == ("Facture télécom", "2018")
    assert nc_sync.classify({"tags": ["Streaming"], "date": MS_2018}) == ("Non classé", "2018")
    assert nc_sync.classify({"tags": ["Facture"], "date": None}) == ("Facture", "Sans date")


def test_identity_documents_file_flat_with_no_year():
    assert nc_sync.classify({"tags": ["Passeport"], "date": MS_2018}) == ("Passeport", None)


def test_names_are_made_safe_and_lose_the_import_suffix():
    assert nc_sync.safe_name("bill__419.pdf") == "bill.pdf"
    assert nc_sync.safe_name("a/b:c?.pdf") == "a_b_c_.pdf"
    assert nc_sync.safe_name("La__ Felicita.pdf") == "La__ Felicita.pdf"
    assert nc_sync.safe_name("  ") == "document"


def test_a_filename_clash_gets_the_doc_id_tail():
    taken = {}
    doc = {"tags": ["Facture"], "date": MS_2018, "name": "bill.pdf"}
    assert nc_sync.target_rel("doc_aaaaaa111111", doc, taken) == "Facture/2018/bill.pdf"
    assert nc_sync.target_rel("doc_bbbbbb222222", doc, taken) == "Facture/2018/bill-222222.pdf"
    # The first one keeps its slot on the next pass.
    assert nc_sync.target_rel("doc_aaaaaa111111", doc, taken) == "Facture/2018/bill.pdf"


class FakePg:
    """Enough psycopg2 for nc_sync: an in-memory oc_storages/oc_filecache/systemtags."""

    def __init__(self, archive, files=None, tags=None, mappings=()):
        self.storage_id = f"local::{archive}/"
        self.mounted = True
        self.files = dict(files or {})  # path -> fileid
        self.tags = dict(tags or {})  # name -> id
        self.mappings = set(mappings)  # (objectid, tagid)
        self.autocommit = False
        self.writes = []
        self.rowcount = -1
        self._rows = []

    def cursor(self):
        return self

    def close(self):
        pass

    def execute(self, sql, params=()):
        s = " ".join(sql.split())
        if s.startswith("SELECT numeric_id FROM oc_storages"):
            self._rows = [(7,)] if self.mounted and params[0] == self.storage_id else []
        elif s.startswith("SELECT path, fileid FROM oc_filecache"):
            self._rows = list(self.files.items())
        elif s.startswith("SELECT name, id FROM oc_systemtag"):
            self._rows = [(n, i) for n, i in self.tags.items() if n in params[0]]
        elif s.startswith("INSERT INTO oc_systemtag("):
            new = max(self.tags.values(), default=100) + 1
            self.tags[params[0]] = new
            self._rows = [(new,)]
            self.writes.append(("tag", params[0]))
        elif s.startswith("SELECT systemtagid FROM oc_systemtag_object_mapping"):
            self._rows = [(t,) for o, t in self.mappings if o == params[0]]
        elif s.startswith("INSERT INTO oc_systemtag_object_mapping"):
            self.mappings.add((params[0], params[1]))
            self.writes.append(("map", params[0], params[1]))
        elif s.startswith("DELETE FROM oc_systemtag_object_mapping m"):
            live = {str(f) for f in self.files.values()}
            gone = {(o, t) for o, t in self.mappings if t in params[0] and o not in live}
            self.mappings -= gone
            self.rowcount = len(gone)
            if gone:
                self.writes.append(("orphans", len(gone)))
        elif s.startswith("DELETE FROM oc_systemtag_object_mapping"):
            self.mappings.discard((params[0], params[1]))
            self.writes.append(("unmap", params[0], params[1]))
        else:
            raise AssertionError(f"unexpected SQL: {s}")

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def fetchall(self):
        return list(self._rows)


class Scanner:
    """Fake `occ files:scan`: indexes every archive file into the FakePg."""

    def __init__(self, archive, pg):
        self.archive, self.pg, self.calls = archive, pg, []

    def __call__(self, argv):
        # Like Nextcloud: a path it already knows keeps its fileid, a path that
        # appeared behind its back (a move) gets a fresh one.
        self.calls.append(argv)
        old, self.pg.files = self.pg.files, {}
        for root, _d, files in os.walk(self.archive):
            for f in files:
                rel = os.path.relpath(os.path.join(root, f), self.archive)
                self.next = getattr(self, "next", 1000) + 1
                self.pg.files[rel] = old.get(rel, self.next)


def archive_env(tmp_path, docs, tags=(), doc_tags=(), dates=None):
    blobs = tmp_path / "blobs"
    blobs.mkdir()
    keys = {}
    for doc_id, *_ in docs:
        (blobs / f"{doc_id}.pdf").write_bytes(doc_id.encode())
        keys[doc_id] = f"{doc_id}.pdf"
    path, con = papra_db(tmp_path, docs, tags, doc_tags, dates, keys)
    archive = tmp_path / "archive"
    archive.mkdir()
    cfg = nc_sync.Config(
        papra_db=str(path), docs_root=str(blobs), archive=str(archive),
        state_dir=str(tmp_path / "state"), owner="no-such-user-here", apply=True)
    pg = FakePg(str(archive))
    return cfg, con, pg, Scanner(str(archive), pg)


def run_sync(cfg, pg, scan, logged):
    return nc_sync.reconcile(cfg, connect=lambda _c: pg, run=scan, log=logged.append)


def listing(root):
    return sorted(os.path.relpath(os.path.join(r, f), root)
                  for r, _d, fs in os.walk(root) for f in fs)


BILL = [("doc_bill01", "org", "bill__419.pdf", "x", None)]
BILL_TAGS = dict(tags=[("t1", "org", "Facture", "facture"), ("t2", "org", "Abonnement", "abonnement")],
                 doc_tags=[("doc_bill01", "t1"), ("doc_bill01", "t2")],
                 dates={"doc_bill01": MS_2018})


def test_a_document_is_filed_and_its_tags_mirrored(tmp_path):
    cfg, con, pg, scan = archive_env(tmp_path, BILL, **BILL_TAGS)
    logged = []
    assert run_sync(cfg, pg, scan, logged) == 0
    assert listing(cfg.archive) == ["Facture/2018/bill.pdf"]
    assert open(os.path.join(cfg.archive, "Facture/2018/bill.pdf"), "rb").read() == b"doc_bill01"
    fid = str(pg.files["Facture/2018/bill.pdf"])
    assert {t for o, t in pg.mappings if o == fid} == {pg.tags["Facture"], pg.tags["Abonnement"]}
    assert pg.autocommit is True
    assert "+1 copied" in logged[-1]


def test_a_second_pass_is_a_no_op(tmp_path):
    cfg, con, pg, scan = archive_env(tmp_path, BILL, **BILL_TAGS)
    run_sync(cfg, pg, scan, [])
    pg.writes.clear()
    scan.calls.clear()
    logged = []
    run_sync(cfg, pg, scan, logged)
    assert pg.writes == [] and scan.calls == []
    assert "+0 copied, 0 moved, 0 pruned" in logged[-1]


def test_a_retag_moves_the_file_and_swaps_its_tags(tmp_path):
    cfg, con, pg, scan = archive_env(tmp_path, BILL, **BILL_TAGS)
    run_sync(cfg, pg, scan, [])
    con.execute("insert into tags values ('t3',0,0,'org','Contrat','#CCCCCC',null,'contrat')")
    con.execute("delete from documents_tags where tag_id='t1'")
    con.execute("insert into documents_tags values ('doc_bill01','t3')")
    con.commit()
    run_sync(cfg, pg, scan, [])
    assert listing(cfg.archive) == ["Contrat/bill.pdf"]
    fid = str(pg.files["Contrat/bill.pdf"])
    assert {t for o, t in pg.mappings if o == fid} == {pg.tags["Contrat"], pg.tags["Abonnement"]}
    # The old fileid's mappings went with it.
    assert {o for o, _t in pg.mappings} == {fid}


def test_a_hand_added_nextcloud_tag_is_left_alone(tmp_path):
    cfg, con, pg, scan = archive_env(tmp_path, BILL, **BILL_TAGS)
    run_sync(cfg, pg, scan, [])
    fid = str(pg.files["Facture/2018/bill.pdf"])
    pg.tags["Mine"] = 999
    pg.mappings.add((fid, 999))
    run_sync(cfg, pg, scan, [])
    assert (fid, 999) in pg.mappings


def test_a_deleted_document_is_pruned_with_its_empty_folders(tmp_path):
    cfg, con, pg, scan = archive_env(
        tmp_path, BILL + [("doc_keep01", "org", "keep.pdf", "x", None)], **BILL_TAGS)
    run_sync(cfg, pg, scan, [])
    con.execute("update documents set deleted_at=1 where id='doc_bill01'")
    con.commit()
    logged = []
    run_sync(cfg, pg, scan, logged)
    assert listing(cfg.archive) == ["Non classé/Sans date/keep.pdf"]
    assert not os.path.exists(os.path.join(cfg.archive, "Facture"))
    assert "1 pruned" in logged[-1]


def test_a_missing_blob_is_skipped_not_fatal(tmp_path):
    cfg, con, pg, scan = archive_env(tmp_path, BILL, **BILL_TAGS)
    os.unlink(os.path.join(cfg.docs_root, "doc_bill01.pdf"))
    logged = []
    assert run_sync(cfg, pg, scan, logged) == 0
    assert listing(cfg.archive) == []
    assert any("blob missing" in line for line in logged)


def test_a_dry_run_writes_nothing(tmp_path):
    cfg, con, pg, scan = archive_env(tmp_path, BILL, **BILL_TAGS)
    cfg = nc_sync.Config(**{**cfg.__dict__, "apply": False})
    logged = []
    assert run_sync(cfg, pg, scan, logged) == 0
    assert listing(cfg.archive) == []
    assert pg.writes == [] and scan.calls == []
    assert not os.path.exists(cfg.manifest)
    assert "(dry-run) 1 filed (+1 copied" in logged[-1]


def test_an_unmounted_archive_fails_the_unit(tmp_path):
    cfg, con, pg, scan = archive_env(tmp_path, BILL, **BILL_TAGS)
    pg.mounted = False
    logged = []
    assert run_sync(cfg, pg, scan, logged) == 1
    assert "papra-nc-archive-mount" in logged[-1]


def test_the_dbpassword_is_read_out_of_nextclouds_config(tmp_path):
    cfg_php = tmp_path / "config.php"
    cfg_php.write_text("<?php $CONFIG = array('dbpassword' => 'p@ss', );")
    assert nc_sync.nc_pg_password(str(cfg_php)) == "p@ss"
    cfg_php.write_text("<?php $CONFIG = array();")
    with pytest.raises(RuntimeError, match="dbpassword not found"):
        nc_sync.nc_pg_password(str(cfg_php))


# ── proton_poll ───────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("ct", "fn", "disp", "size", "expected"),
    [
        ("application/pdf", "bill.pdf", "attachment", 100, True),
        ("application/octet-stream", "bill.pdf", "inline", 100, True),  # ext wins
        ("text/calendar", "invite.ics", "attachment", 100000, False),
        ("application/pdf", "invite.ics", "attachment", 100000, False),  # .ics always out
        ("image/png", "scan.png", "attachment", 50000, True),
        ("image/png", "logo.png", "attachment", 1000, False),  # below the size floor
        ("image/png", "logo.png", "inline", 50000, False),  # inline, not an attachment
        ("text/html", "body.html", "attachment", 50000, False),
        ("", None, None, 0, False),
    ],
)
def test_only_document_like_attachments_are_taken(ct, fn, disp, size, expected):
    assert proton_poll.is_doc(ct, fn, disp, size) is expected


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("bill.pdf", "bill.pdf"),
        ("../../etc/passwd", "passwd"),
        ("/absolute/path.pdf", "path.pdf"),
        ("facture; rm -rf.pdf", "facture_ rm -rf.pdf"),
        ("é@#$.pdf", "____.pdf"),
        (None, "attachment"),
        ("", "attachment"),
    ],
)
def test_attachment_filenames_are_sanitised(raw, expected):
    # This name comes from an email header — i.e. from anyone who can mail you.
    assert proton_poll.safe(raw) == expected


def test_a_colliding_filename_gets_a_suffix():
    taken = {"/d/bill.pdf", "/d/bill-1.pdf"}
    assert proton_poll.unique_dest("/d/bill.pdf", exists=taken.__contains__) == "/d/bill-2.pdf"
    assert proton_poll.unique_dest("/d/new.pdf", exists=taken.__contains__) == "/d/new.pdf"


def test_an_attachment_lands_via_a_temporary_name(tmp_path):
    # Papra's watcher must never see a partially-written file.
    seen = []
    cfg = proton_poll.Config(dest=str(tmp_path))
    dest = proton_poll.save_attachment(cfg, b"%PDF-1.7", "bill.pdf", chown=seen.append)
    assert dest == str(tmp_path / "bill.pdf")
    assert (tmp_path / "bill.pdf").read_bytes() == b"%PDF-1.7"
    assert not (tmp_path / "bill.pdf.incoming").exists()
    assert seen == [str(tmp_path / "bill.pdf.incoming"), str(tmp_path / "bill.pdf")]


def make_message(message_id, parts):
    """parts: (content_type, filename, disposition, payload)."""
    lines = [
        "From: sender@example.com",
        f"Message-ID: {message_id}",
        "MIME-Version: 1.0",
        'Content-Type: multipart/mixed; boundary="BOUND"',
        "",
    ]
    for ct, fn, disp, payload in parts:
        lines += [
            "--BOUND",
            f"Content-Type: {ct}" + (f'; name="{fn}"' if fn else ""),
            f"Content-Disposition: {disp}" + (f'; filename="{fn}"' if fn else ""),
            "Content-Transfer-Encoding: base64",
            "",
            base64.b64encode(payload).decode(),
        ]
    lines.append("--BOUND--")
    return email.message_from_string("\r\n".join(lines))


class FakeImap:
    def __init__(self, messages, select_ok=True):
        self.messages = messages
        self.select_ok = select_ok
        self.searched = None
        self.selected = None
        self.logged_out = False

    def select(self, mbox, readonly=False):
        self.selected = (mbox, readonly)
        return ("OK" if self.select_ok else "NO"), [b""]

    def search(self, charset, *criteria):
        self.searched = criteria
        return "OK", [b" ".join(str(i).encode() for i in range(1, len(self.messages) + 1))]

    def fetch(self, num, spec):
        msg = self.messages[int(num) - 1]
        return "OK", [(b"1 (RFC822 {})", msg.as_bytes())]

    def logout(self):
        self.logged_out = True


def test_a_labelled_message_drops_its_documents(tmp_path):
    msg = make_message("<m1@x>", [
        ("application/pdf", "bill.pdf", "attachment", b"%PDF-1.7"),
        ("text/calendar", "invite.ics", "attachment", b"BEGIN:VCALENDAR"),
        ("image/png", "logo.png", "attachment", b"x" * 100),
    ])
    dest = tmp_path / "ingest"
    dest.mkdir()
    cfg = proton_poll.Config(dest=str(dest), state_dir=str(tmp_path), mailbox="All Mail")
    imap = FakeImap([msg])
    saved, newseen = proton_poll.poll(cfg, imap, log=lambda _m: None, chown=lambda _p: None)
    assert saved == 1  # the .ics and the tiny logo are not documents
    assert [p.name for p in dest.iterdir()] == ["bill.pdf"]
    assert newseen == ["<m1@x>"]
    # A mailbox name with a space must be quoted, and never opened for writing.
    assert imap.selected == ('"All Mail"', True)
    assert imap.searched == ("KEYWORD", "papra")


def test_an_already_seen_message_is_not_reprocessed(tmp_path):
    msg = make_message("<m1@x>", [("application/pdf", "bill.pdf", "attachment", b"%PDF")])
    dest = tmp_path / "ingest"
    dest.mkdir()
    (tmp_path / "seen").write_text("<m1@x>\n")
    cfg = proton_poll.Config(dest=str(dest), state_dir=str(tmp_path))
    saved, newseen = proton_poll.poll(
        cfg, FakeImap([msg]), log=lambda _m: None, chown=lambda _p: None)
    assert (saved, newseen) == (0, [])
    assert list(dest.iterdir()) == []


def test_a_message_with_no_documents_is_still_recorded(tmp_path):
    # Otherwise every poll re-scans and re-fetches it forever.
    msg = make_message("<m2@x>", [("text/calendar", "i.ics", "attachment", b"BEGIN")])
    dest = tmp_path / "ingest"
    dest.mkdir()
    cfg = proton_poll.Config(dest=str(dest), state_dir=str(tmp_path))
    saved, newseen = proton_poll.poll(
        cfg, FakeImap([msg]), log=lambda _m: None, chown=lambda _p: None)
    assert (saved, newseen) == (0, ["<m2@x>"])


def test_an_unselectable_mailbox_is_an_error_not_an_empty_run(tmp_path):
    cfg = proton_poll.Config(dest=str(tmp_path), state_dir=str(tmp_path))
    with pytest.raises(RuntimeError, match="cannot select"):
        proton_poll.poll(cfg, FakeImap([], select_ok=False))


def test_main_refuses_to_run_without_a_destination(capsys):
    assert proton_poll.main(env={}) == 1
    assert "PAPRA_PROTON_DEST" in capsys.readouterr().err


def test_main_appends_to_the_seen_file_and_logs_out(tmp_path):
    msg = make_message("<m3@x>", [("application/pdf", "b.pdf", "attachment", b"%PDF")])
    dest = tmp_path / "ingest"
    (tmp_path / "seen").write_text("<old@x>\n")
    imap = FakeImap([msg])
    env = {"PAPRA_PROTON_DEST": str(dest), "PAPRA_PROTON_STATE_DIR": str(tmp_path)}
    assert proton_poll.main(env=env, imap=imap) == 0
    assert (tmp_path / "seen").read_text() == "<old@x>\n<m3@x>\n"
    assert imap.logged_out is True
