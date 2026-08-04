---
name: mtg-commander-strategy
description: Use when creating a rigorous, read-only Commander pilot guide for a finished deck.
version: 1.2.0
author: Dan Blanchard, Nico + Hermes Agent
license: 0BSD
metadata:
  hermes:
    emoji: "🧭"
    tags: [mtg, commander, edh, strategy, pilot-guide, moxfield, rules]
    related_skills: [mtg-commander-deckbuilding]
---

# Commander Strategy Guide

Create a rigorous, read-only pilot guide for a finished Commander deck. Explain its game plan, sequencing, mulligans, threat assessment, table play, win lines, and load-bearing rules interactions. Do not propose adds, cuts, or tuning; route those to `mtg-commander-deckbuilding`.

Commander-only MCP-native adaptation of `dan-blanchard/mtg-skills` `deck-strat` (0BSD). It preserves its analysis and rules-evidence discipline while replacing unavailable local CLIs, downloaded data, workspace files, and direct APIs with installed MTG MCP tools. Source: <https://github.com/dan-blanchard/mtg-skills>.

## Iron Rule

Never assume what a card or rule does. Training data is neither Oracle text nor the Comprehensive Rules.

- Retrieve `mcp__mtg__get_card_details` for the commander and every card central to a claimed line.
- For a rules-adjacent claim, retrieve exact card text, then published rulings where useful with `mcp__mtg__get_card_rulings`, then the decisive CR evidence: known rule with `mcp__mtg__get_rule`; unknown rule with `mcp__mtg__search_rules` then `get_rule`; keyword with `mcp__mtg__get_glossary_term`.
- For nuanced multi-rule stack, replacement-effect, or layer reasoning, retrieve every decisive rule and state the limits of the conclusion. Do not manufacture a citation or claim certainty beyond the retrieved evidence.

A wrong claim about command-zone replacement, targeting, trigger ordering, or timing makes the guide untrustworthy.

## Scope and Inputs

- **In scope:** finished, public Commander lists from Moxfield or Archidekt, or a user-supplied commander plus complete list.
- **Out of scope:** list construction, upgrades, collection filtering, and 60-card formats. Route deck changes to `mtg-commander-deckbuilding`.
- Fetch a public source via `mcp__mtg__get_moxfield_deck` or `mcp__mtg__get_archidekt_deck`. Confirm deck name, Commander format, commander(s), command zone, and mainboard. If the commander is unclear, ask; never infer it from the first card.
- Ask for the intended play context: bracket/power target and experience level (beginner, intermediate, advanced). If absent, assume ordinary casual multiplayer and intermediate prose. Do not auto-assign a bracket: MCP has no reliable Game Changer/aggregate combo analysis.

## MCP Boundaries

| Need | Installed MCP path | Limitation |
|---|---|---|
| Public list | `mcp__mtg__get_moxfield_deck`, `mcp__mtg__get_archidekt_deck` | Read-only public retrieval. |
| Oracle/type/identity/legality | `mcp__mtg__get_card_details` | Retrieve named cards; do not assume old or digital text. |
| Targeted mechanic search | `mcp__mtg__search_cards` | Use valid Scryfall syntax and color identity filters. |
| Official rulings and CR | `mcp__mtg__get_card_rulings`, `get_rule`, `search_rules`, `get_glossary_term` | Search results are leads; retrieve the decisive full rule before citing it. |
| Community context | `mcp__mtg__get_edhrec_recommendations` | Popularity is not proof of a line, bracket, legality, or deck fit. Zero/malformed counts are unavailable data. |

No local cache, bulk download, direct Scryfall/EDHREC/Commander Spellbook API, simulated games, matchup statistics, or automatic combo/bracket rating is available. Never imply that one was used. No reliable MCP combo/near-miss detector is available.

## Workflow

### 1. Acquire and establish context

1. Fetch or parse the supplied complete list; verify commander(s), format, and every named card used in the eventual guide.
2. Ask for bracket/power and experience level. Respect an explicit answer. If absent, label assumptions rather than claiming a precise bracket.
3. Retrieve commander details and map actual deck roles: ramp, card advantage, interaction, protection, recursion, finishers, and cards that must survive.
4. Retrieve card details for likely engine pieces, payoff cards, and each card in a proposed line. Record alternative-cost cards (flashback, escape, evoke, foretell, suspend, adventure, etc.); evaluate their real usable cost, not only printed mana value.

### 2. Commander interaction audit

Perform each dimension below against the actual list. Omit it from the final guide only if it does not apply; do not fabricate one.

1. **Keyword combinations.** Check commander keywords and keywords granted by deck cards for emergent effects: evasion restrictions, double strike with combat-damage triggers, trample plus deathtouch, and redundant versus complementary protection.
2. **Trigger multiplication.** Identify extra combats, turns, phases, trigger copying, token doubling, or other multipliers. State the realistic multiplied output only after verifying the trigger text and timing.
3. **Feedback loops.** Find cards whose output feeds a commander's trigger/input or another engine: counters scaling power, tokens increasing a count, theft changing a relevant type, and similar loops.
4. **Recurring cards.** Identify reusable spells/permanents (buyback, retrace, escape, flashback, self-return, re-suspend). Describe per-game value and setup requirements.
5. **Commander multiplication.** Identify in-list effects that copy the commander, copy/duplicate relevant triggers, or create additional activation windows. Verify legend-rule, copy, trigger, and timing claims before writing them. Do not certify deck legality here; route legality requests to `mtg-commander-deckbuilding`.
6. **Combos and near-misses.** Identify only manually verified lines whose pieces are actually in the list. No reliable MCP combo/near-miss detector is available: do not invoke `mcp__mtg__get_edhrec_combos` and do not imply exhaustive detection. Verify every card, mana condition, order, result, and disruption point. A missing-piece line is informational only and must never become an upgrade recommendation.

### 3. Archetype and table analysis

Infer archetypes only from verified Oracle text and the actual list. Check for and describe, where present:

- Tokens/token doublers; sacrifice outlets/aristocrats; reanimation; goad/politics; extra combats/turns; big mana; Voltron; ETB multiplication; graveyard engines; stax/control; spell-slinging.
- The primary loop, secondary plan, and realistic backup win condition.
- Threats that actually stop this deck’s engine (graveyard hate, creature wipes, artifact removal, counterspells, specific taxes, etc.). Do not fabricate matchup statistics or claim a universal threat list.
- Public EDHREC data only as context to sanity-check an archetype or identify deliberate omissions. If its counts/inclusion data are zero, missing, or malformed, omit community comparisons.

### 4. Rules verification pass

Before drafting, list every rules-adjacent statement you intend to make. Verify all of them before presenting:

| Claim | Evidence path |
|---|---|
| Card behavior / in-list interaction | `mcp__mtg__get_card_details` for every central card |
| Published card edge case | `mcp__mtg__get_card_rulings` |
| Keyword | `mcp__mtg__get_glossary_term`, then rule if needed |
| Known CR rule | `mcp__mtg__get_rule` |
| Unknown rule or phrase | `mcp__mtg__search_rules`, then `get_rule` |
| Command-zone, stack, replacement, layers | Card details plus every decisive CR rule; give a bounded conclusion |

Cite the exact rule number and only the needed sentence fragment. Do not quote a rule until it has been retrieved. If evidence is unavailable or ambiguous, say so and avoid presenting the claim as settled.

### 5. Write the primer

Render this fixed core, in order:

1. **Identity and core loop:** deck name, commander(s), color identity, archetype, realistic pace, engine pieces, and terminal effect.
2. **Win conditions:** primary, secondary, and tertiary plans actually present; order by realistic likelihood.
3. **Mulligan guide:** keep/ship rubric based on mana, colors, ramp, early engines, and bracket context. State the Commander free-mulligan rule only with retrieved rules evidence.
4. **Turn pacing:** turns 1–3, midgame, and closing turns; identify the setup-to-harvest transition and when to deploy/hold the commander.
5. **Threat assessment and interaction:** what to answer, when to hold interaction, protection priorities, and what hate is most disruptive to this list.
6. **Common lines and stack/timing notes:** only verified in-list lines. For each combo, give prerequisites, ordered actions, result, and disruption points.
7. **Deck quirks and cheat sheet:** unusual card interactions, recurring triggers, alternative-cost reminders, and concise per-turn prompts a pilot should remember.
8. **Verified interaction notes:** concise direct verdicts with Oracle/ruling/CR citations for non-obvious claims.

Add conditional sections only when evidenced by the list: politics scripts, aristocrats sequencing, combo execution, Voltron commander-damage math, token-doubling math, extra-combat/turn sequencing, reanimation lines, big-mana payoffs, or ETB multiplication.

## Output Rules

- Use concise Telegram headings and bullets; provide a full primer only when requested. For one play question, return only the relevant verified section.
- Adapt depth: define terms for beginners; use normal terminology for intermediate players; compress familiar explanations for advanced players. Rules evidence remains required at every level.
- Do not make unsolicited deck changes. A deliberate omission may be described; no card should be suggested as an add/cut.
- Do not claim testing, simulations, statistics, complete combo detection, or exact bracket placement unless separately performed with a verified source.

## Quality Gate

- [ ] Source, Commander format, commander(s), command zone, and mainboard verified.
- [ ] Every named card and line is present in the actual list.
- [ ] Commander and every load-bearing card retrieved via card details.
- [ ] Every non-obvious mechanical claim has Oracle/ruling/CR evidence.
- [ ] Every combo has verified prerequisites, actions, result, and disruption points.
- [ ] Mulligan, pacing, interaction, closing, and table-play advice are specific to this deck.
- [ ] No upgrades, invented bracket rating, or unverified community/statistical claim.

### Independent rules audit — hard gate

Before delivery, dispatch an independent reviewer to audit every rules-adjacent sentence in the draft. Give the reviewer the complete deck list, each claim, and its retrieved Oracle text/rulings/CR evidence. The reviewer must return only:

- **Errors:** a claim conflicts with retrieved evidence; correct or remove it.
- **Unsupported:** a claim lacks decisive evidence; retrieve it, qualify it, or remove it.
- **Verified:** evidence supports the claim; retain it.

Revise every error/unsupported claim, then re-run the independent audit. Deliver only after it returns zero errors and zero unsupported claims. The audit is rules-only: it must not introduce upgrade recommendations, direct APIs, files, or a deleted rules-skill dependency.

## Red Flags

- “I know what this card/rule does.” → Retrieve it.
- “This obvious interaction needs no citation.” → Verify it.
- “EDHREC says it, so it fits/is legal.” → Popularity is not proof.
- “The user knows the deck, so skip mulligans or cheat sheet.” → Keep the core structure; be concise if needed.
- “A nearby combo is an in-list win line.” → It is not. Verify exact pieces or omit it.
- “I should fold a swap into strategy advice.” → Route it to `mtg-commander-deckbuilding`.
