# nic-os — agent instructions

## Git identity: always commit and open PRs as `nSimonFR-ai`

All commits and pull requests in this repository MUST be authored by the
**`nSimonFR-ai`** GitHub account (the acting / automation account) — never
`nSimonFR` (the owner account).

- **Commits** — author them as `nSimonFR-ai`. If the checkout's git author is not
  already `nSimonFR-ai`, set it explicitly, e.g.
  `git -c user.name="nSimonFR-ai" -c user.email="265587706+nSimonFR-ai@users.noreply.github.com" commit …`
  (or configure `user.name` / `user.email` for the checkout). End commit messages
  with the standard `Co-Authored-By:` trailer.
- **Pull requests** — open them with `gh` authenticated as `nSimonFR-ai`.
- **`nSimonFR` owns and merges.** `nSimonFR-ai` is not an admin and `main`'s branch
  protection requires a review with no bypass actor, so `nSimonFR-ai` cannot merge
  its own PRs. Leave merging to `nSimonFR` (the user) — do not attempt to self-merge.
