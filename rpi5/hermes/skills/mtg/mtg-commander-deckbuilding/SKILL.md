---
name: mtg-commander-deckbuilding
description: Use when building or upgrading a Commander deck with rigorous, interactive swaps.
version: 1.3.0
author: guuse, P47Phoenix, Nico + Hermes Agent
license: MIT
metadata:
  hermes:
    emoji: "🏗️"
    tags: [mtg, commander, edh, deckbuilding, upgrades, moxfield, validation, budget]
    related_skills: [mtg-commander-strategy]
---

# MTG Commander Deckbuilding

Build Commander decks or make an existing 100-card deck meaningfully better through a rigorous, interactive diagnosis-and-swap workflow. This is adapted from guuse’s MIT `mtg-edh-upgrade` (the quality/process source) and P47Phoenix’s Apache-2.0 `mtg-commander` architecture. Their scripts, local databases, direct Scryfall/Archidekt requests, workspace writes, and automatic sync are replaced by the installed MTG MCP. See `references/methodology.md` and `references/synergy.md` before an upgrade.

Sources: https://github.com/guuse/claude-mtg-skills ; https://github.com/P47Phoenix/Claude-Plugins/tree/main/mtg-commander

## When to Use

- A user pastes or links an existing Commander deck and asks to upgrade, tune, optimize, repair, cut, or add cards.
- The user asks for a complete Commander build or rebuild under a target power and budget.
- The user needs a Commander deck diagnosis, legality evidence, or collection-aware swap plan.

Do not use for a pilot guide; load `mtg-commander-strategy` instead. For standalone rules questions, use the MTG MCP’s card-details, rulings, and Comprehensive Rules tools directly.

## MCP Replacements and Limits

| Need | Installed tool |
|---|---|
| Public Moxfield/Archidekt deck | `mcp__mtg__get_moxfield_deck`, `mcp__mtg__get_archidekt_deck` |
| Comparable published Archidekt lists | `mcp__mtg__search_archidekt_decks`, then `mcp__mtg__get_archidekt_deck` |
| Oracle text, type, identity, legality | `mcp__mtg__get_card_details` |
| Commander-legal candidate search | `mcp__mtg__search_cards` |
| Current Commander ban list | `mcp__mtg__get_banned_list` |
| Deck size and singleton | `mcp__mtg__validate_deck` |
| Current per-card price snapshot | `mcp__mtg__get_card_price` |
| Commander usage/candidate pool | `mcp__mtg__get_edhrec_recommendations`, `mcp__mtg__get_edhrec_combos` |

- Never run upstream Python scripts, build/download a local card database, call direct Scryfall/EDHREC/Moxfield/Archidekt APIs, create a `.mtg` workspace, or sync/push user data.
- The MCP has no Cardmarket total, average-deck endpoint, role tags, automated bracket analyzer, or file-presentation equivalent. Do not invent their output. Price only requested/high-impact cards; identify currency/source and never count unavailable prices as zero.
- `mcp__mtg__validate_deck` verifies size and singleton only. Full Commander legality requires current ban-list plus per-card identity/legality checks. Its one-commander interface also requires manual partner/background-style command-zone verification.
- Assert owned-only compliance only from a supplied readable collection export or verified collection data. Otherwise say ownership is unverified.

## Upgrade: Interactive Diagnosis and Swaps

An upgrade is **not** a rebuild. Respect cards the user owns and likes; make a small number of high-impact, role-preserving swaps first. Work conversationally: do not dump a rewritten 100-card list or write files before the user accepts changes.

### 1. Acquire and inspect

1. Fetch a supplied public deck through the deck MCP tools, or parse the pasted list. Confirm commander, command zone, format, card count, and unclear entries. If the list is malformed/ambiguous, state what was found and ask for correction.
2. Retrieve commander details. Establish its existing engine and color identity; sharpen that plan unless the user asks to re-pivot.
3. Read `references/methodology.md`, then tally lands/fixing, ramp, net-positive card advantage, interaction, wipes, protection, curve, engines, and real closing lines. Read `references/synergy.md` for themed candidate selection.

### 2. Hear the user, then agree priorities

Before prescribing cards, ask concise questions only where not supplied:

- What actually fails in games: slow starts, mana, cards, resilience, closing, or a table-specific matchup?
- What should improve: speed, grind, resilience, theme, or target power?
- What is protected: pet cards, owned-only requirement, prior failed experiments, exclusions?
- What target power/bracket and total upgrade budget apply?

Their lived problems outrank a structural tally. Surface material unmentioned gaps, but agree the top 2–3 priorities before proposing cards.

### 3. Establish candidates

1. Ground candidate choices in comparables. Use meaningful EDHREC recommendations/inclusion data when available. Also—or when its counts/inclusion data are zero, missing, or malformed—use `mcp__mtg__search_archidekt_decks` for 1–2 relevant public lists, then fetch them with `mcp__mtg__get_archidekt_deck` and compare role counts/card overlap. Label these as selected published examples, not aggregate inclusion-rate evidence. If neither source is usable, state reduced confidence and rely on explicit synergy/role reasoning. EDHREC is never proof of fit, legality, price, or rules.
2. Use `mcp__mtg__search_cards` for precise role/theme searches, then retrieve exact details for each serious candidate. Every themed add must fix a named gap and normally show at least two concrete synergy contacts; structural cards are exceptions. Name those contacts.
3. Search only in command-zone identity (`id<=…` syntax). Confirm each selected card’s identity/Commander legality from details; never infer it from frame color or mana production.
4. For each add, propose a cut serving the same or lower-priority role. Keep the deck at 100 cards including command zone and preserve pet cards unless the user accepts removal.
5. Price requested candidates and plausible cap breakers with `mcp__mtg__get_card_price`. If a high-impact add exceeds budget, find a cheaper legal same-role option. If none is adequate, leave the existing card and move to the next priority; do not buy a downgrade just to spend money.

### 4. Propose, discuss, iterate

Present changes in small priority batches: **Cut → Add — shared role/reason — price snapshot — running spend**. Offer 2–3 real alternatives where appropriate. Invite vetoes and adjustments. Only after the user accepts the change set, assemble the final list.

If the budget cannot make the deck a solid version of the requested target, say so plainly; offer a larger budget for specific load-bearing cards or a lower target. Never claim a target the evidence does not support.

### 5. Final legality and quality gate

1. Recount roles and confirm the agreed priority gaps improved.
2. Run `mcp__mtg__validate_deck` with commander separate from the 99-card mainboard for deck size and singleton.
3. Retrieve the current ban list. For every nonbasic—and unusual basic—retrieve card details to confirm Commander legality and identity within the command zone. Manually verify multi-commander compatibility, quantities, and explicit restrictions.
4. For non-obvious interactions, retrieve exact Oracle text, published rulings where useful, then the decisive Comprehensive Rule (known number: `mcp__mtg__get_rule`; unknown: `mcp__mtg__search_rules` then `get_rule`; keyword: `mcp__mtg__get_glossary_term`). Give prerequisites, ordered actions, result, disruption point, and only the evidence that decides it. Call a line a synergy rather than a combo if it is not deterministic.
5. If a check fails, make only necessary corrections and repeat the whole gate. Do not call the deck legal until all checks pass.

## Build or Rebuild

For a new build, obtain commander/desire, strategy, power target, budget, restrictions, ownership constraint, and complete command zone. Verify commander(s), color identity, and bans; build a coherent 100-card role map; then use the same candidate, interaction, budget, and final-legality gates above. A full rebuild must return the complete flat list—not only suggestions.

## Output

### Upgrade review

Use: **Snapshot**, **What works**, **Problems**, **Accepted changes**, **Remaining/future upgrades**. Include before → after role counts, confirmed legality status, cuts/adds with reasons, price snapshot/running spend if requested, and explicit uncertainty around budget, power, or playgroup.

### Full build/rebuild

1. Snapshot: commander(s), plan, assumptions, restrictions, and legality evidence.
2. Why it works: role counts plus 3–6 final-list interactions.
3. Decklist: one code block with quantities and card names only—no categories or comments.
4. Budget: only when requested; source/currency, priced/unpriced cards, confirmed total/lower bound/inconclusive status.
5. One next option: pilot guide, price trimming, collection-only pass, or alternate power target.

Create, save, attach, or sync deck files only when the user explicitly requests it. Do not claim native Telegram rich delivery unless the actual delivery surface supports and confirms it.

## Common Pitfalls

1. **One-shot replacement.** Upgrades are interactive; seek acceptance before locking final lists.
2. **Validator overreach.** Size/singleton output alone does not establish bans, identity, or special command zones.
3. **Bad budget substitution.** A cheaper card must preserve the role; otherwise keep the current card.
4. **Theme overclaim.** Character/gender/art restrictions require exact printing-specific verification.
5. **False ownership claim.** Popularity or low price is not collection evidence.
6. **Price-source drift.** A single MCP price is not a market survey, cheapest printing, sealed-product price, or Cardmarket total.

## Verification Checklist

- [ ] Current list/command zone and user pain points were confirmed before recommendations.
- [ ] Diagnosis and priorities follow `references/methodology.md`.
- [ ] Themed adds follow `references/synergy.md`; every swap is role-preserving.
- [ ] User accepted the upgrade set before finalization.
- [ ] Final list has exactly 100 cards including command zone.
- [ ] Validator passes for size/singleton; bans, per-card legality/identity, and special command zone were checked.
- [ ] Budget/price claims identify source/currency and unresolved values.
- [ ] Full decklists are flat and Moxfield-importable; file writes happened only if requested.
