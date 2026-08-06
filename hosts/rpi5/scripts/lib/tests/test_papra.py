"""The three Papra units.

All three were previously unimportable off-host: tag_sweep opened SQLite at
module level, tag_sync and proton_poll read `os.environ[...]` at module level and
raised KeyError. The first thing these tests prove is that importing them does
nothing at all — the rest covers the webhook's signature check (auth), the
sweeper's EX_TEMPFAIL contract, and the drop-zone's filename handling.
"""

import base64
import email
import hashlib
import hmac
import json
import sqlite3
import urllib.error
import urllib.request

import pytest
from conftest import FakeOpener, json_reply

from nicos_scripts.papra import proton_poll, tag_sweep, tag_sync

# ── importability ─────────────────────────────────────────────────────────────


def test_the_modules_have_no_import_time_side_effects():
    # A Config built from an empty env must not raise, open a socket, or touch disk.
    # This is the whole reason these three moved into the package.
    assert tag_sweep.Config.from_env({}).db == "/var/lib/papra/db.sqlite"
    assert tag_sync.Config.from_env({}).secret == b""
    assert proton_poll.Config.from_env({}).dest == ""


# ── tag_sweep ─────────────────────────────────────────────────────────────────


def papra_db(tmp_path, docs, tags=(), doc_tags=()):
    """docs: (id, org, name, content, deleted_at). tags: (id, org, name, norm)."""
    path = tmp_path / "papra.sqlite"
    con = sqlite3.connect(str(path))
    con.execute(
        "create table documents (id text primary key, organization_id text, name text,"
        " original_name text, content text, deleted_at integer)"
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
            "insert into documents values (?,?,?,?,?,?)",
            (doc_id, org, name, name, content, deleted),
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
    assert schema["required"] == ["existingTags", "newTags"]


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


# ── tag_sync: the signature check is the auth boundary ─────────────────────────

SECRET = b"s3cret"
BODY = b'{"event":"document.tags.changed","documentId":"doc_abcdefghij123456"}'


def signed(secret, wid="msg_1", wts="1700000000", body=BODY):
    signed_content = wid.encode() + b"." + wts.encode() + b"." + body
    mac = hmac.new(secret, signed_content, hashlib.sha256).digest()
    return f"v1,{base64.b64encode(mac).decode()}"


def test_a_correctly_signed_payload_is_accepted():
    ok, _, _ = verify(signed(SECRET))
    assert ok is True


def verify(sig, secret=SECRET, wid="msg_1", wts="1700000000", body=BODY):
    return tag_sync.verify_signature(secret, wid, wts, sig, body)


def test_a_tampered_body_is_rejected():
    ok, _, _ = tag_sync.verify_signature(
        SECRET, "msg_1", "1700000000", signed(SECRET), BODY + b"tampered")
    assert ok is False


def test_a_replayed_signature_under_a_different_id_is_rejected():
    ok, _, _ = tag_sync.verify_signature(
        SECRET, "msg_2", "1700000000", signed(SECRET, wid="msg_1"), BODY)
    assert ok is False


def test_a_signature_from_the_wrong_secret_is_rejected():
    ok, _, _ = verify(signed(b"wrong"))
    assert ok is False


def test_a_missing_or_malformed_signature_header_is_rejected():
    for header in ("", "garbage", "v2,abc", "v1"):
        ok, _, _ = verify(header)
        assert ok is False


def test_several_signatures_are_accepted_if_any_matches():
    # svix sends multiple during secret rotation.
    ok, _, sigs = verify(f"v1,AAAA {signed(SECRET)}")
    assert ok is True
    assert len(sigs) == 2


def test_a_whsec_prefixed_secret_is_base64_decoded_first():
    raw = b"\x01\x02\x03\x04"
    secret = b"whsec_" + base64.b64encode(raw)
    ok, _, _ = tag_sync.verify_signature(
        secret, "msg_1", "1700000000", signed(raw), BODY)
    assert ok is True


def test_doc_ids_are_extracted_in_order_without_duplicates():
    body = b'{"a":"doc_aaaaaaaaaaaaaaaa","b":"doc_bbbbbbbbbbbbbbbb","c":"doc_aaaaaaaaaaaaaaaa"}'
    assert tag_sync.doc_ids(body) == ["doc_aaaaaaaaaaaaaaaa", "doc_bbbbbbbbbbbbbbbb"]


def test_a_payload_with_no_doc_id_yields_nothing():
    assert tag_sync.doc_ids(b'{"event":"ping"}') == []
    assert tag_sync.doc_ids(b"doc_tooshort") == []


# ── tag_sync: the Nextcloud write path ────────────────────────────────────────


def label(sql):
    """First few words of a statement — enough to identify it in an assertion."""
    return " ".join(" ".join(sql.split()).split(" ")[:3])


class FakePg:
    """Just enough psycopg2 to drive apply_systemtags/find_file.

    `answers` is consulted by SQL prefix; every execute is recorded so the tests can
    assert what would have been written to Nextcloud's database.
    """

    def __init__(self, file_row=None, existing_tag_ids=(), mapped=()):
        self.file_row = file_row
        self.existing = dict(existing_tag_ids)
        self.mapped = set(mapped)
        self.executed = []
        self.autocommit = False
        self._next = None
        self._new_id = 500

    def cursor(self):
        return self

    def execute(self, sql, params=()):
        self.executed.append((label(sql), params))
        if sql.startswith("SELECT fc.fileid"):
            self._next = self.file_row
        elif sql.startswith("SELECT id FROM oc_systemtag "):
            tid = self.existing.get(params[0])
            self._next = (tid,) if tid else None
        elif sql.startswith("INSERT INTO oc_systemtag("):
            self._new_id += 1
            self.existing[params[0]] = self._new_id
            self._next = (self._new_id,)
        elif sql.startswith("SELECT 1 FROM oc_systemtag_object_mapping"):
            self._next = (1,) if (params[0], params[1]) in self.mapped else None
        elif sql.startswith("INSERT INTO oc_systemtag_object_mapping"):
            self.mapped.add((params[0], params[1]))
            self._next = None
        else:
            self._next = None

    def fetchone(self):
        return self._next

    def close(self):
        pass

    @property
    def writes(self):
        return [e for e in self.executed if e[0].startswith("INSERT")]


def sync_db(tmp_path, original_name, tags):
    path, con = papra_db(
        tmp_path,
        docs=[("doc_aaaaaaaaaaaaaaaa", "org", original_name, "x", None)],
        tags=[(f"t{i}", "org", t, t.lower()) for i, t in enumerate(tags)],
        doc_tags=[("doc_aaaaaaaaaaaaaaaa", f"t{i}") for i in range(len(tags))],
    )
    con.close()
    return tag_sync.Config(papra_db=str(path), secret=SECRET)


def test_tags_are_mirrored_as_systemtags(tmp_path):
    cfg = sync_db(tmp_path, "bill.pdf", ["Facture"])
    pg = FakePg(file_row=(42, "files/bill.pdf"))
    out = tag_sync.sync(cfg, "doc_aaaaaaaaaaaaaaaa", connect=lambda _cfg: pg)
    assert "tagged files/bill.pdf (fileid 42) -> ['Facture']" in out
    assert pg.writes == [
        ("INSERT INTO oc_systemtag(name,visibility,editable)", ("Facture",)),
        ("INSERT INTO oc_systemtag_object_mapping(objectid,objecttype,systemtagid)", ("42", 501)),
    ]
    assert pg.autocommit is True


def test_an_existing_systemtag_is_reused_not_duplicated(tmp_path):
    cfg = sync_db(tmp_path, "bill.pdf", ["Facture"])
    pg = FakePg(file_row=(42, "files/bill.pdf"), existing_tag_ids={"Facture": 7})
    tag_sync.sync(cfg, "doc_aaaaaaaaaaaaaaaa", connect=lambda _cfg: pg)
    assert pg.writes == [
        ("INSERT INTO oc_systemtag_object_mapping(objectid,objecttype,systemtagid)", ("42", 7)),
    ]


def test_an_already_mapped_tag_writes_nothing(tmp_path):
    # Papra fires the webhook on every tag change; re-delivery must be a no-op.
    cfg = sync_db(tmp_path, "bill.pdf", ["Facture"])
    pg = FakePg(file_row=(42, "f/bill.pdf"), existing_tag_ids={"Facture": 7},
                mapped=[("42", 7)])
    tag_sync.sync(cfg, "doc_aaaaaaaaaaaaaaaa", connect=lambda _cfg: pg)
    assert pg.writes == []


def test_a_document_with_no_nextcloud_file_is_skipped(tmp_path):
    cfg = sync_db(tmp_path, "proton-only.pdf", ["Facture"])
    pg = FakePg(file_row=None)
    out = tag_sync.sync(cfg, "doc_aaaaaaaaaaaaaaaa", connect=lambda _cfg: pg)
    assert "no Nextcloud file" in out
    assert pg.writes == []


def test_an_untagged_document_is_skipped_without_touching_postgres(tmp_path):
    cfg = sync_db(tmp_path, "bill.pdf", [])

    def boom(_cfg):
        raise AssertionError("must not connect")

    assert "no tags yet" in tag_sync.sync(cfg, "doc_aaaaaaaaaaaaaaaa", connect=boom)


def test_an_unknown_document_is_skipped_without_touching_postgres(tmp_path):
    cfg = sync_db(tmp_path, "bill.pdf", ["Facture"])

    def boom(_cfg):
        raise AssertionError("must not connect")

    assert "unknown/deleted" in tag_sync.sync(cfg, "doc_zzzzzzzzzzzzzzzz", connect=boom)


def test_the_paperless_import_suffix_is_tried_as_a_fallback_name():
    assert tag_sync.candidate_names("bill__2.pdf") == ["bill__2.pdf", "bill.pdf"]
    assert tag_sync.candidate_names("bill.pdf") == ["bill.pdf"]
    assert tag_sync.candidate_names("no__suffix") == ["no__suffix"]


def test_the_file_lookup_is_scoped_to_the_users_own_storage():
    pg = FakePg(file_row=(1, "p"))
    tag_sync.find_file(pg, "nsimon", ["bill.pdf"])
    assert pg.executed[0][1] == ("bill.pdf", "home::nsimon")


def test_the_dbpassword_is_read_out_of_nextclouds_config(tmp_path):
    cfg_php = tmp_path / "config.php"
    cfg_php.write_text("<?php $CONFIG = array('dbpassword' => 'p@ss', );")
    assert tag_sync.nc_pg_password(str(cfg_php)) == "p@ss"
    cfg_php.write_text("<?php $CONFIG = array();")
    with pytest.raises(RuntimeError, match="dbpassword not found"):
        tag_sync.nc_pg_password(str(cfg_php))


def test_main_refuses_to_serve_without_a_webhook_secret(capsys):
    # Serving with an empty secret would accept forged webhooks.
    assert tag_sync.main(env={}) == 1
    assert "refusing to accept" in capsys.readouterr().err


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
