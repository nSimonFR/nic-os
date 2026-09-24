import json

from session_link import SessionLinks, parent_of, session_of

A = "4088e70f-11d7-44e8-9253-15d89fa975dc"
B = "02dfeb2e-6872-4979-b08d-92db2f770899"
C = "3d36d9eb-6f1a-4878-b691-74ca17b95e7b"


def continuation(parent: str) -> str:
    return (
        "This session is being continued from a previous conversation that ran out "
        "of context. The summary below covers the earlier portion of the conversation."
        "\n\nSummary:\n1. **Primary Request** mentions other-9fe8e7dc-623a-4327-a21f-"
        "cd50327101f4.jsonl in passing\n\nIf you need specific details from before "
        "compaction (like exact code snippets, error messages, or content you "
        "generated), read the full transcript at: /Users/nsimon/.claude/projects/"
        f"-Users-nsimon-x/{parent}.jsonl"
    )


def body(sid: str, parent: str | None = None, as_string: bool = False) -> dict:
    blocks = [{"type": "text", "text": "<system-reminder>CLAUDE.md …</system-reminder>"}]
    if parent:
        blocks.append({"type": "text", "text": continuation(parent)})
    content = continuation(parent) if (as_string and parent) else blocks
    user_id = {"device_id": "d", "account_uuid": "a", "session_id": sid}
    return {
        "model": "claude-opus-5-5",
        "messages": [{"role": "user", "content": content}, {"role": "assistant", "content": "ok"}],
        "metadata": {"user_id": json.dumps(user_id)},
    }


def test_parent_from_block_and_string_content():
    assert parent_of(body(B, A)) == A
    assert parent_of(body(B, A, as_string=True)) == A


def test_no_parent_for_a_fresh_session():
    assert parent_of(body(A)) is None


def test_summary_quoted_later_in_the_conversation_is_ignored():
    b = body(A)
    b["messages"].append({"role": "user", "content": continuation(C)})
    assert parent_of(b) is None


def test_fresh_session_is_untouched(tmp_path):
    links = SessionLinks(tmp_path / "links.json")
    b = body(A)
    assert links.link(b) is None
    assert session_of(b) == A
    assert not (tmp_path / "links.json").exists()


def test_chain_maps_to_root_and_keeps_other_user_id_fields(tmp_path):
    links = SessionLinks(tmp_path / "links.json")
    assert links.link(body(B, A)) == A
    b = body(C, B)
    assert links.link(b) == A
    user_id = json.loads(b["metadata"]["user_id"])
    assert user_id == {"device_id": "d", "account_uuid": "a", "session_id": A}


def test_user_id_formatting_is_preserved_byte_for_byte(tmp_path):
    links = SessionLinks(tmp_path / "links.json")
    b = body(B, A)
    before = b["metadata"]["user_id"]  # json.dumps default: spaced
    links.link(b)
    assert b["metadata"]["user_id"] == before.replace(B, A)


def test_later_requests_without_the_summary_still_map(tmp_path):
    # after the next compaction messages[0] no longer names the grandparent
    links = SessionLinks(tmp_path / "links.json")
    links.link(body(B, A))
    b = body(B)
    assert links.link(b) == A


def test_links_survive_a_restart(tmp_path):
    SessionLinks(tmp_path / "links.json").link(body(B, A))
    SessionLinks(tmp_path / "links.json").link(body(C, B))
    assert SessionLinks(tmp_path / "links.json").root(C) == A


def test_cycle_does_not_hang(tmp_path):
    links = SessionLinks(tmp_path / "links.json")
    links.observe(A, B)
    links.observe(B, A)
    assert links.root(A) in {A, B}


def test_self_reference_is_ignored(tmp_path):
    links = SessionLinks(tmp_path / "links.json")
    assert links.link(body(A, A)) is None


def test_corrupt_or_missing_state_starts_empty(tmp_path):
    (tmp_path / "links.json").write_text("{not json")
    assert SessionLinks(tmp_path / "links.json").parents == {}
    assert SessionLinks(tmp_path / "nope.json").parents == {}


def test_body_without_metadata_is_untouched(tmp_path):
    links = SessionLinks(tmp_path / "links.json")
    b = {"messages": [{"role": "user", "content": continuation(A)}]}
    assert links.link(b) is None
    assert "metadata" not in b
