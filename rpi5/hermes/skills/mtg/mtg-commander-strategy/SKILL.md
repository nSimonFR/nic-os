---
name: mtg-commander-strategy
description: Use when creating a Commander pilot guide from a finished deck.
version: 1.0.0
author: Nico + Hermes Agent
license: 0BSD
metadata:
  hermes:
    emoji: "🧭"
    tags: [mtg, commander, edh, strategy, pilot-guide, moxfield, rules]
    related_skills: [mtg-deck-analysis]
---

# Commander Strategy Guide

## Overview

Create a read-only, evidence-backed guide for piloting a finished Commander deck. It explains game plan, sequencing, mulligans, interaction, win conditions, politics, and key rules interactions. It does not make cuts or additions; route deck changes to `mtg-deck-analysis`.

Commander-only adaptation of `dan-blanchard/mtg-skills` `deck-strat` (0BSD), using the installed MTG MCP instead of its local `mtg_utils` CLI and downloaded rules/card-data workflow. Source reviewed: https://github.com/dan-blanchard/mtg-skills

## When to Use

- The user asks how to pilot, sequence, mulligan, or play an existing Commander deck.
- The user wants a deck primer or guide for a Moxfield/Archidekt list.
- The user asks for combo lines, recurring engines, key interactions, or threat assessment for a finished deck.

Do not use for deck construction, upgrades, or collection filtering; load `mtg-deck-analysis` instead.

## Workflow

1. **Acquire and verify the list.** Fetch the supplied public Moxfield or Archidekt deck. Confirm name, format, commander(s), command zone, and mainboard before analysing. If the commander is not clear, ask; never infer it from the first listed card.
2. **Establish the play context.** Use the stated Commander bracket/power target. If absent, state that the guide assumes ordinary casual multiplayer rather than claiming a precise bracket.
3. **Ground card claims.** Retrieve exact Oracle text for the commander and every card used in a specific line or interaction. Do not rely on memory for card behavior.
4. **Map the deck.** Identify primary plan, secondary plan, ramp, card advantage, interaction, protection, recursion, finishers, and cards that must be kept alive. Verify each category against the actual list.
5. **Check interactions.** Use the MTG tools to search official rules, retrieve precise rules, and retrieve card rulings for every non-obvious timing, replacement-effect, layer, commander-zone, or multiplayer claim. Cite the actual rule number and relevant text. If no authoritative result is available, say so rather than inventing a ruling.
6. **Write the primer.** Include the sections below. A section may be brief when inapplicable, but do not fabricate a combo, politics plan, or backup win condition.
7. **Quality gate.** Re-check that every named card is in the deck, every rules claim has an authoritative citation, and the output contains no upgrade recommendations.

## Required Primer Structure

### Snapshot
- Commander(s), color identity, primary plan, and realistic game pace.
- One sentence on what the deck is trying to do before it wins.

### Mulligans and early turns
- Keep/ship rubric based on mana, colors, ramp, and the deck's actual early engine pieces.
- Turns 1–3 priorities, including when to deploy the commander.

### Midgame
- Engine assembly, resource priorities, interaction discipline, and which threats deserve answers.
- Sequencing rules for draw, ramp, sacrifice, combat, or graveyard engines when relevant.

### Closing games
- Primary win lines and backup plans actually present in the deck.
- For each combo: prerequisites, ordered actions, disruption points, and the resulting game state.

### Table play
- Threat presentation, politics, and when to hold versus commit. Keep this specific to the deck and multiplayer Commander; omit generic advice.

### Rules and interaction notes
- Only non-obvious items. For each, give a direct verdict plus exact Comprehensive Rules and/or official card-ruling citations.

## Rules Evidence Standard

- Use `mcp__mtg__get_rule` for a known rule number.
- Use `mcp__mtg__search_rules` or `mcp__mtg__get_glossary_term` to locate the applicable rule when the number is unknown.
- Use `mcp__mtg__get_card_rulings` for published card-specific rulings.
- Cite rule numbers only when returned by an MTG tool in the current task. Do not quote a remembered rule number.
- Distinguish Oracle text, official rulings, and strategic advice. EDHREC data can describe usage, not establish a rules interaction.

## Output

- Use concise Telegram headings and bullets.
- Quote only the sentence fragment needed to support a rule conclusion.
- Include a full primer only when asked; for a single play question, return the relevant section instead.
- Do not claim simulated games, matchup statistics, or testing unless they were actually performed.

## Common Pitfalls

1. **Turning the guide into a deck review.** Do not suggest cuts/additions. Link the user back to an analysis request.
2. **Assuming a card's text.** Verify Oracle text, especially for old printings, Universes Beyond cards, and digital variants.
3. **Inventing rules citations.** A plausible but incorrect CR number is worse than no citation.
4. **Treating EDHREC as proof.** Popularity data does not prove legality, sequencing, or rules behavior.
5. **Overstating combo certainty.** Call a line a synergy unless the exact cards, mana, and outcome are verified.

## Verification Checklist

- [ ] Deck source, format, commander(s), and board contents verified.
- [ ] Every named line uses cards present in the deck.
- [ ] Exact Oracle text checked for cards central to the guide.
- [ ] Every rules claim includes a tool-backed rule/ruling citation.
- [ ] Primer contains no unsolicited upgrade recommendations.
- [ ] Mulligan, early-game, midgame, closing, and table-play guidance reflect this deck.
