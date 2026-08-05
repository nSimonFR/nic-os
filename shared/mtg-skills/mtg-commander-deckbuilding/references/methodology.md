# Upgrade Methodology

## Target shape

These are deliberate guidelines, not quotas:

- **Lands:** ~37–38; 36–37 only with a low curve and cheap draw. Multicolor decks need reliable fixing.
- **Card advantage:** ≥12 net-positive pieces; roughly eight at MV ≤3 and four explosive higher-MV sources. Looting/rummaging alone is not net-positive.
- **Ramp:** ~10–11 efficient pieces, plus explosive mana only when the target bracket supports it.
- **Interaction:** ~10 dedicated answers plus 2–4 board wipes, scaled for target bracket.
- **Win conditions:** 3–4 repeatable, resilient closers from a normal board state.
- **Curve:** MV 6+ cards must swing the board immediately; avoid a top-heavy pile.

A Commander deck is a machine, not a top-99 list. Its 99 should still function if the commander is removed.

## Diagnose first

1. Retrieve the supplied public deck through MCP or parse the pasted list. Confirm commander, format, and complete command zone.
2. Get exact commander details; extract its engine and color identity. Sharpen the existing plan unless the user asks for a pivot.
3. Tally actual role counts and compare to the target shape. Identify the largest 2–3 gaps: mana, draw, ramp, interaction, curve, cohesion, or closing power.
4. Ground the diagnosis in comparables. Use meaningful EDHREC recommendation/inclusion data when available. Also—or if those values are zero, missing, or malformed—search 1–2 relevant public Archidekt lists with `mcp__mtg__search_archidekt_decks`, fetch them with `mcp__mtg__get_archidekt_deck`, and compare role counts/card overlap. They are selected published examples, not aggregate inclusion-rate evidence. If neither source is usable, disclose reduced confidence and use explicit role/synergy reasoning.
5. Reconcile the diagnosis with the user’s play experience. Their reported problems outrank a purely structural tally; raise unmentioned material gaps and ask whether they want them addressed.

## Actual bracket and target

Ask for a bracket/power target when it would change choices. Do not manufacture an official bracket from unsupported data. Report observed power signals—fast mana, tutors, Game Changer candidates, compact early combos, mass land denial, chained extra turns—and distinguish those observations from the user’s target. Verify each material card/rule claim with current MCP evidence.

## Choose adds and cuts

- Every add must fix a named gap or have a stated synergy reason.
- For every add, name a role-preserving cut: off-theme filler, overcosted curve burden, win-more card, or weaker duplicate effect.
- Preserve pet cards unless the user accepts their removal.
- Keep the list exactly 100 cards including command zone.
- When a budget blocks a high-impact add, find a cheaper legal card serving the same role. If no adequate substitute exists, leave the current card and move to another priority rather than spending on a downgrade.
- If the stated budget cannot reach the target, say so; offer a higher budget for specific load-bearing upgrades or a lower target.

## Re-check

After every accepted swap set:

1. Recount roles and confirm the named gaps improved.
2. Re-run size/singleton validation with `mcp__mtg__validate_deck`.
3. Retrieve current bans and per-card details to confirm Commander legality and color identity; manually check special command-zone compatibility.
4. State before → after role counts, accepted changes, spend versus cap, remaining gaps, and observed power-signal changes.

## Final check

- [ ] Diagnosis is grounded in the actual deck plus user-reported pain points.
- [ ] Each addition has a named gap or synergy reason; each cut is role-preserving.
- [ ] Budget is respected or an honest shortfall is stated.
- [ ] Mainboard/card count, bans, color identity, and special command zone are verified.
- [ ] Final list is exactly 100 cards including command zone.
- [ ] Final output distinguishes facts from subjective tuning advice.
