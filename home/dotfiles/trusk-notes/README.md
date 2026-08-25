# Trusk deep notes

Long-form companions to `../CLAUDE.md`, which stays short because it loads into **every**
Trusk session. These do not load automatically — the main file links to them, and you read
the one you need.

**Source of truth:** `~/nic-os/home/dotfiles/trusk-notes/`, symlinked by home-manager to
`~/MyDocuments/TRUSK/notes/`. Edit either path (out-of-store symlink, no rebuild needed),
then commit in nic-os.

| note | read it when |
|---|---|
| [`advisory-locks.md`](./advisory-locks.md) | anything touches `lockBuilder`, a service wedges under concurrency, or you see `advisory-lock pool saturated` / `timeout exceeded when trying to connect` |
| [`metastable-staging.md`](./metastable-staging.md) | **before** trusting any staging performance measurement, or when a restart fails to fix a saturated service |
| [`roundtrip-tour-size.md`](./roundtrip-tour-size.md) | tour creation times out, or you want the worked example of a four-layer latency chase |
| [`merge-and-ci-traps.md`](./merge-and-ci-traps.md) | `gh pr merge` refuses, local tests disagree with CI, or a dependency bump misbehaves |

## Adding one

A note earns a file when it is (a) longer than a paragraph, (b) still true in six months,
and (c) not derivable from the code or git history. Otherwise it belongs in `../CLAUDE.md`
as a line, or nowhere.

Keep the main file's pointer to one line. Cross-link between notes rather than repeating.
Cite the PR, ticket or measurement behind a claim — an assertion with no source is the
thing a future session cannot check and will not trust.
