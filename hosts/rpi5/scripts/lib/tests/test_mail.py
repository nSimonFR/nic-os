"""Mail store + deterministic digest.

The interesting cases are the ones a live inbox found: an IMAP UID that moves,
a message that disappears, and a second run that must cost nothing.
"""

import datetime

import pytest

from nicos_scripts.mail import digest, fetch, jev, store

NOW = "2026-09-27T08:30:00+00:00"


def gmail_env(mid, subject="Subject", sender="A <a@b.io>", role="work"):
    return {"id": mid, "source": "gmail:me@x.io", "account": role,
            "threadId": "t" + mid, "from": sender, "subject": subject,
            "date": "2026-09-26", "body": "body"}


def fake_post(urgent_subjects=()):
    def post(url, key, payload, timeout=30, opener=None):
        urgent = any(s in payload["state"] for s in urgent_subjects)
        return {"answers": {
            "needs_reply": {"noul": 0.9 if urgent else 0.02},
            "deadline": {"noul": 0.8 if urgent else 0.01},
            "money": {"noul": 0.1}, "security": {"noul": 0.1},
            "human_sender": {"noul": 0.5}, "bulk": {"noul": 0.05},
            "urgency": {"score": 3.0 if urgent else 0.0},
            "disposition": {"choice": "top_action" if urgent else "leave",
                            "confidence": 0.8}},
            "usage": {"input_tokens": 100}}
    return post


@pytest.fixture
def conn(tmp_path):
    return store.connect(str(tmp_path / "mail.db"))


@pytest.fixture
def cfg(tmp_path):
    # proton_user blank on purpose: it defaults to a real account, and `collect`
    # would then read /run/agenix/protonmail-bridge-password.
    return digest.Config(db=str(tmp_path / "mail.db"),
                         gmail=(("work", "me@x.io"),), proton_user="")


# ── identity ────────────────────────────────────────────────────────────────

def test_imap_key_survives_a_uid_change():
    """UIDs are scoped to UIDVALIDITY; the row must not fork when one moves."""
    a = {"source": "proton:1", "id": "22", "from": "a@b.io",
         "subject": "Hi", "date": "Mon, 1 Sep 2026"}
    b = dict(a, id="9931")
    assert store.key_for(a) == store.key_for(b)
    assert store.key_for(a).startswith("imap:")


def test_gmail_key_uses_the_provider_id():
    assert store.key_for(gmail_env("1a0d")) == "gmail:1a0d"


# ── store ───────────────────────────────────────────────────────────────────

def test_upsert_is_idempotent_and_keeps_history(conn):
    store.upsert_seen(conn, [gmail_env("1")], NOW)
    store.save_classification(
        conn, "gmail:1", {"signals": {"bulk": 0.5}, "rank": 2.0,
                          "disposition": "top_action",
                          "disposition_confidence": 0.9,
                          "usage": {"input_tokens": 100}}, "jev-1.13.0", NOW)
    conn.commit()
    store.mark_surfaced(conn, ["gmail:1"], NOW)

    store.upsert_seen(conn, [gmail_env("1", subject="Subject")], "2026-09-28T08:30:00+00:00")
    row = conn.execute("SELECT * FROM messages").fetchone()
    assert conn.execute("SELECT COUNT(*) c FROM messages").fetchone()["c"] == 1
    assert row["surfaced_count"] == 1          # counters survive a re-fetch
    assert row["classified_at"] == NOW         # and so does the verdict
    assert row["last_seen"].startswith("2026-09-28")


def test_reconcile_marks_a_vanished_message_gone(conn):
    store.upsert_seen(conn, [gmail_env("1"), gmail_env("2")], NOW)
    stale = store.reconcile(conn, ["work"], ["gmail:1"], NOW)
    assert stale == 1
    states = dict(conn.execute("SELECT key, state FROM messages").fetchall())
    assert states["gmail:2"] == "gone"
    assert states["gmail:1"] == "unread"


def test_reconcile_ignores_other_accounts(conn):
    store.upsert_seen(conn, [gmail_env("1", role="personal")], NOW)
    assert store.reconcile(conn, ["work"], [], NOW) == 0


def test_live_ranked_excludes_gone_and_unclassified(conn):
    store.upsert_seen(conn, [gmail_env("1"), gmail_env("2")], NOW)
    store.save_classification(conn, "gmail:1", {"signals": {}, "rank": 1.0},
                              "jev-1.13.0", NOW)
    conn.commit()
    assert [r["key"] for r in store.live_ranked(conn)] == ["gmail:1"]


# ── classify once ───────────────────────────────────────────────────────────

def test_second_run_classifies_nothing(cfg, conn):
    store.upsert_seen(conn, [gmail_env("1"), gmail_env("2")], NOW)
    pending = store.unclassified(conn)
    first = digest.classify_pending(cfg, conn, pending, NOW, post=fake_post())
    assert first["messages"] == 2 and first["input_tokens"] == 200

    second = digest.classify_pending(cfg, conn, store.unclassified(conn), NOW,
                                     post=fake_post())
    assert second["messages"] == 0
    assert second["input_tokens"] == 0          # a re-run is free
    assert store.spend(conn)["input_tokens"] == 200


def test_classification_records_the_model(cfg, conn):
    store.upsert_seen(conn, [gmail_env("1")], NOW)
    digest.classify_pending(cfg, conn, store.unclassified(conn), NOW,
                            post=fake_post())
    row = conn.execute("SELECT jev_model FROM messages").fetchone()
    assert row["jev_model"] == jev.DEFAULT_MODEL


# ── rendering ───────────────────────────────────────────────────────────────

def test_trim_strips_reply_prefix_and_keeps_sender():
    out = digest.trim({"subject": "Re:  Feuille de temps", "sender": "m <i@m.com>"})
    assert out == "m — Feuille de temps"


def test_bullet_links_and_nags():
    row = {"subject": "S", "sender": "n", "url": "https://x/1", "surfaced_count": 2}
    out = digest.bullet(row)
    assert out.startswith("- [n — S](https://x/1)")
    assert "3ᵉ jour" in out                      # told you twice already


def test_bullet_without_url_has_no_link():
    assert digest.bullet({"subject": "S", "sender": "", "url": ""}) == "- S"


def test_section_folds_past_the_threshold():
    rows = [{"subject": f"s{i}", "sender": "", "url": ""} for i in range(6)]
    assert "<details>" in "\n".join(digest.section("Read if time", "📖", rows))
    assert "<details>" not in "\n".join(digest.section("T", "⚡", rows[:3]))


def test_render_is_a_rich_message_skeleton():
    buckets = {"top_actions": [{"subject": "A", "sender": "", "url": ""}],
               "read_if_time": [], "delete_spam": [], "archive": []}
    out = digest.render(buckets, {"work": {"unread": 12, "important": 3}},
                        datetime.datetime(2026, 9, 27))
    assert out.startswith("# 📬 Daily mail — Sunday 27 September")
    assert "| Work | 12 | 3 |" in out
    assert "- [ ]" not in out                    # no checkboxes


# ── failure must not look like calm ─────────────────────────────────────────

def test_unreadable_mailbox_raises_rather_than_returning_empty(cfg):
    class Proc:
        returncode = 1
        stdout = ""
        stderr = "keyring locked"

    with pytest.raises(fetch.FetchFailed):
        digest.collect(cfg, "in:inbox", run=lambda *a, **k: Proc())


def test_gog_is_asked_for_bodies(cfg):
    seen = {}

    class Proc:
        returncode = 0
        stdout = "[]"
        stderr = ""

    def run(cmd, **kwargs):
        seen["cmd"] = cmd
        return Proc()

    digest.collect(cfg, "in:inbox", run=run)
    assert "--include-body" in seen["cmd"]
    assert "--wrap-untrusted" in seen["cmd"]


# ── the classifier survived the move ────────────────────────────────────────

def test_jev_self_test_still_passes(capsys):
    assert jev.self_test() == 0
    assert "FAIL" not in capsys.readouterr().out


# ── normalisation at the store boundary ─────────────────────────────────────

WRAPPED = ('<<<EXTERNAL_UNTRUSTED_CONTENT id="0123456789abcdef">>>\n'
           "Source: google_api\n---\nReal subject\n"
           '<<<END_EXTERNAL_UNTRUSTED_CONTENT id="0123456789abcdef">>>')


def test_normalise_unwraps_before_storing():
    """A wrapped subject in the store is a wrapped subject in the digest."""
    row = digest.normalise({"subject": WRAPPED, "from": "A <a@b.io>",
                            "threadId": "t1", "source": "gmail:me@x.io"})
    assert row["subject"] == "Real subject"


def test_normalise_maps_gogs_thread_spelling():
    row = digest.normalise({"subject": "S", "from": "", "threadId": "t1",
                            "source": "gmail:me@x.io"})
    assert row["thread"] == "t1"
    assert row["url"].endswith("#all/t1")


def test_one_thread_collapses_after_normalise(conn):
    """Two messages of one thread must not fill two digest slots."""
    envs = [digest.normalise(dict(gmail_env(str(i), subject=f"S{i}"),
                                  threadId="same")) for i in (1, 2)]
    store.upsert_seen(conn, envs, NOW)
    for key in [store.key_for(e) for e in envs]:
        store.save_classification(conn, key, {"signals": {}, "rank": 1.0,
                                              "disposition": "leave"},
                                  "jev-1.13.0", NOW)
    conn.commit()
    ranked = [digest.as_result(r) for r in store.live_ranked(conn)]
    assert len(jev.dedupe(ranked)) == 1


def test_blank_proton_user_skips_imap_entirely(cfg):
    """Otherwise a test — or a Gmail-only deploy — reads a secret it should not."""
    class Proc:
        returncode = 0
        stdout = "[]"
        stderr = ""

    def boom(*a, **k):
        raise AssertionError("IMAP must not be touched")

    assert digest.collect(cfg, "in:inbox", run=lambda *a, **k: Proc(),
                          connect=boom) == []
