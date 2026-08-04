---
name: mtg-commander-deckbuilding
description: Use when building, rebuilding, reviewing, upgrading, or validating a Commander deck.
version: 1.1.0
author: P47Phoenix, Nico + Hermes Agent
license: Apache-2.0
metadata:
  hermes:
    emoji: "🏗️"
    tags: [mtg, commander, edh, deckbuilding, moxfield, validation, budget]
    related_skills: [mtg-commander-strategy, mtg-rules-citations]
---

# MTG Commander Deckbuilding

MCP-native workflow for existing-deck reviews and complete Commander builds. It combines a focused review/upgrade process with P47Phoenix’s Apache-2.0 `mtg-commander` pipeline, replacing its Python scripts, local config, and direct Scryfall/Archidekt calls with the installed MTG MCP.

Upstream architecture: https://github.com/P47Phoenix/Claude-Plugins/tree/main/mtg-commander

## When to Use

- Build or rebuild a complete Commander deck.
- Review, tune, upgrade, or validate a Moxfield/Archidekt Commander list.
- Compare a deck or proposed changes against a supplied collection export.

Do not use for a pilot guide or standalone rules question. Load `mtg-commander-strategy` or `mtg-rules-citations`.

## MCP Evidence

| Need | Tool |
|---|---|
| Public deck | `mcp__mtg__get_moxfield_deck`, `mcp__mtg__get_archidekt_deck` |
| Card name, Oracle text, type, identity, legality | `mcp__mtg__get_card_details` |
| Candidate discovery | `mcp__mtg__search_cards` |
| Current Commander ban list | `mcp__mtg__get_banned_list` |
| Deck size and singleton | `mcp__mtg__validate_deck` |
| Current card price snapshot | `mcp__mtg__get_card_price` |
| Commander candidate ideas | `mcp__mtg__get_edhrec_recommendations`, `mcp__mtg__get_edhrec_combos` |

Use `mtg-rules-citations` for any non-obvious mechanical conclusion. EDHREC is a candidate source, never proof of fit, legality, price, or rules.

## Boundaries

- Never use upstream Python scripts or direct Scryfall/Archidekt API calls.
- Price data is a current snapshot; identify currency/source and never treat an unavailable price as $0.
- `mcp__mtg__validate_deck` currently verifies deck size and singleton. Complete legality with the current ban list and per-card `mcp__mtg__get_card_details` evidence for Commander legality and color identity.
- Its one-commander interface does not validate partner/background-style command zones. Verify command-zone compatibility manually from current Oracle text/rules.
- Assert owned-only compliance only from a supplied readable collection export or other verified collection data. Otherwise label ownership unverified.
- For a full list, return exactly 100 cards including command zone and a flat Moxfield-importable decklist. Write/export a file only when requested.

## Mode A — Analyze or Tune an Existing Deck

1. **Acquire.** Fetch the provided Moxfield/Archidekt deck through MCP. Confirm format, command zone, mainboard, and relevant boards.
2. **Diagnose actual list.** Review lands/fixing, ramp, card advantage, interaction, protection, curve, cohesion, recurring engines, finishers, and isolated filler. Count roles from the actual list, not generic targets.
3. **Check constraints.** Verify proposed additions against Commander legality/color identity. If owned-only, compare against supplied verified collection data.
4. **Recommend.** Give priority order: diagnosis, best additions, first cuts, concrete swaps, then optional purchases. For a requested rebuild, switch to Mode B.

For theme restrictions, establish whether the rule applies to game pieces, named characters, or specific printing artwork. Do not claim character/gender/art compliance without checking the exact printing; mark unresolved candidates as pending printing-art verification.

## Mode B — Build or Rebuild

### Intake

Use what the user already gave. Ask only for material gaps: commander or desired colors, strategy, power/bracket, budget, restrictions, owned-only requirement, and complete command zone.

For commander suggestions, search Commander-legal candidates, then verify each candidate’s Oracle text/type before calling it command-zone eligible.

### Build

1. Verify commander(s), combined color identity, and current bans.
2. Use EDHREC and targeted card search only to form a candidate pool; check card details for selected cards when role, text, or identity is material.
3. Construct 100 cards including command zone. Use a coherent role map: lands, ramp, draw, interaction, protection, engine/payoffs, recursion, and finishers.
4. State the plan and any deliberate trade-off. Do not mechanically require “three interactions per nonland.”

### Legality gate

1. Run `mcp__mtg__validate_deck` with the commander separate from the 99-card mainboard for size and singleton.
2. Retrieve the current ban list and reject every banned card.
3. For every nonbasic card—and unusual basic land—retrieve card details and confirm Commander legality plus identity within the command zone.
4. Manually verify multi-commander compatibility, quantities, and stated restrictions.
5. On any failure, make only necessary replacements and repeat the entire gate. Do not call the deck legal until all checks pass.

### Structure, interaction, and budget

- Identify material role deficits, curve issues, color-source failures, and cards that do not serve plan, support, mana, interaction, or a stated theme.
- For a claimed combo, give prerequisites, ordered actions, result, and disruption points. Call it a synergy when it is not deterministic.
- Use `mtg-rules-citations` when a rules conclusion is load-bearing.
- Price only when requested or budgeted. Check plausible cap breakers first; for a full total, identify unpriced cards and report a lower bound or inconclusive result rather than estimating.
- After every budget swap, repeat the legality gate.

## Output

### Existing-deck review

Use concise sections: **Snapshot**, **What works**, **Problems**, **Changes**, **Future upgrades**. Give concrete additions/cuts/swaps and state uncertainty about budget, power, or playgroup.

### Full build/rebuild

1. Snapshot: commander(s), plan, power assumptions, restrictions, and legality result.
2. Why it works: role counts and 3–6 final-list interactions.
3. Decklist: a code block containing only quantities and card names—no categories or comments.
4. Budget: only if requested; source/currency, priced/unpriced cards, and total status.
5. One next option: pilot guide, price trimming, collection conversion, or another power target.

## Common Pitfalls

1. **Validator overreach.** It does not by itself prove color identity or bans; perform the full evidence gate.
2. **Invalid shared command zone.** A legendary creature is not automatically compatible with another commander.
3. **Theme overclaim.** Art/gender/character themes require printing-specific verification.
4. **False ownership claim.** A popular or cheap card is not evidence Nico owns it.
5. **Price-source drift.** Do not call one MCP price a cheapest printing, Card Kingdom price, sealed-product price, or market survey.
6. **No-op full rebuild.** A rebuild must provide the complete validated 100-card flat list, not only ideas.

## Verification Checklist

- [ ] Deck source or intake, command zone, restrictions, and plan are explicit.
- [ ] Full lists contain exactly 100 cards including command zone.
- [ ] Validator passes for size/singleton; ban-list and per-card legal/identity checks pass.
- [ ] Each non-obvious rules claim follows `mtg-rules-citations`.
- [ ] Every claimed interaction uses cards in the final list.
- [ ] Owned-only claims rely on verified supplied collection data.
- [ ] Price claims identify source/currency and do not hide unavailable values.
- [ ] Final full decklist is flat and Moxfield-importable.
