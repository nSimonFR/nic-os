---
name: mtg-commander-architect
description: Use when building a complete Commander deck via a validated pipeline.
version: 1.0.0
author: P47Phoenix, adapted by Nico + Hermes Agent
license: Apache-2.0
metadata:
  hermes:
    emoji: "🏗️"
    tags: [mtg, commander, edh, deckbuilding, validation, budget, moxfield]
    related_skills: [mtg-deck-analysis, mtg-rules-citations, mtg-commander-strategy]
---

# MTG Commander Deck Architect

Build a complete, Moxfield-importable 100-card Commander deck through a staged builder → legality → structure → budget pipeline. This is a **MCP-native adaptation** of P47Phoenix’s Apache-2.0 `mtg-commander` skill: no Python scripts, local Scryfall download, config file, or direct API calls are used.

Upstream source cloned and reviewed: https://github.com/P47Phoenix/Claude-Plugins/tree/main/mtg-commander

## When to Use

- The user asks for a complete new 100-card Commander deck.
- The user specifies a commander/archetype/budget and expects legality and structure checks.
- The user wants a rigorous rebuild rather than a small upgrade package.

Do not use for a few swaps, collection-only filtering, or a pilot guide. Use `mtg-deck-analysis` or `mtg-commander-strategy` instead.

## Boundaries

- The installed MTG MCP is the source of card data, legality, rules, EDHREC, and supported price checks. Never invoke an upstream Python script or direct Scryfall/Archidekt endpoint.
- Do not promise dual-vendor, cheapest-printing, or bulk pricing: the installed MCP price tool returns current card price data per requested card, not the upstream script’s Card Kingdom/TCGPlayer batch workflow.
- Price checks are a snapshot. State pricing source/currency and date, and label any unavailable price as unavailable rather than estimating it.
- Build **exactly 100 cards including commander(s)**. Use `mcp__mtg__validate_deck` for its deck-size/singleton checks, plus current ban-list and per-card MCP checks for full legality; do not treat an LLM review as a substitute.
- For an owned-cards-only deck, require a supplied collection export or verified collection data before presenting ownership claims. If a collection workflow skill is installed in the active Hermes environment, use it; otherwise treat ownership as unverified and provide a buy-list rather than claiming the list is owned-only.

## Intake

Extract what the user already supplied. Ask only for material missing information:

| Input | Default / handling |
|---|---|
| Commander | Required, unless they ask for suggestions. |
| Strategy | Infer only when the commander strongly indicates one; label it as inferred. |
| Power / bracket | Ask if it materially affects construction; otherwise state casual-focused assumptions. |
| Budget | No price cap when omitted. |
| Restrictions | Include/exclude cards, combos, themes, owned-only, per-card cap. |
| Partner/background | Ask for the complete command zone; never reject it merely because it has a partner-like ability. |

For commander suggestions, use `mcp__mtg__search_cards` with Commander-legal Scryfall syntax, then retrieve exact details for shortlisted options. Never claim a candidate can be a commander before checking its Oracle text/type.

## MCP Tool Map

| Need | Required tool |
|---|---|
| Commander/card Oracle text, identity, type | `mcp__mtg__get_card_details` |
| Candidate discovery | `mcp__mtg__search_cards` |
| Format ban list | `mcp__mtg__get_banned_list` |
| Deck size and singleton validation | `mcp__mtg__validate_deck` |
| Rules interactions | `mcp__mtg__get_rule`, `mcp__mtg__search_rules`, `mcp__mtg__get_card_rulings` |
| Current card price snapshot | `mcp__mtg__get_card_price` |
| Commander usage ideas | `mcp__mtg__get_edhrec_recommendations` and `mcp__mtg__get_edhrec_combos` |
| Existing public deck baseline | `mcp__mtg__get_moxfield_deck` or `mcp__mtg__get_archidekt_deck` |

## Pipeline

Keep artefacts compact: intake, a flat decklist, role counts, the legality result, and any price snapshot. Independent reviews are useful, but do not claim artificial independence if no separate agent is available.

### 1. Builder

1. Verify commander(s) with `mcp__mtg__get_card_details`; verify the named card exists, is eligible as commander, and determine combined color identity.
2. Check current bans with `mcp__mtg__get_banned_list`.
3. Retrieve EDHREC recommendations only as a candidate pool. EDHREC popularity is not proof of fit, legality, or price.
4. Search card candidates by role using precise Scryfall queries with `mcp__mtg__search_cards`. Check exact details for every chosen card whose identity, text, or role is non-obvious.
5. Construct a 100-card list including commander(s). Start from a coherent skeleton appropriate to the plan, then count actual roles rather than forcing generic quotas.
6. Output a flat preliminary list plus a short role map: lands, ramp, draw, interaction, protection, engine/payoffs, and finishers.

Completion: 100 cards are listed, strategy/restrictions are addressed, and no card is included on an unverified name.

### 2. Legality Judge

Use a fresh review context when available. Run `mcp__mtg__validate_deck` with the commander and **99-card mainboard only** (or the appropriate command-zone structure supported by the tool). It verifies deck size and singleton. Its current response explicitly says full color-identity and banned-card validation requires per-card checks, so complete the remaining checks with MCP evidence:

1. Retrieve `mcp__mtg__get_banned_list` and reject every listed card.
2. Retrieve `mcp__mtg__get_card_details` for every nonbasic card (and every basic-land name used if nonstandard); confirm Commander legality and that its reported color identity is a subset of the commander's combined identity.
3. Check command-zone composition and all stated restrictions manually.
4. Confirm basic-land quantities and that no card name was lost while formatting.

If any check fails, give the Builder the exact evidence, replace only affected cards, and re-run the whole validation sequence. Never report a legal deck until size, singleton, per-card Commander legality/color identity, and current ban-list checks all pass.

### 3. Structure and Synergy Review

Review the actual list—not a remembered template.

- Count lands, mana acceleration, card advantage, targeted interaction, board control, protection, recursion, and closing lines.
- Calculate/inspect mana curve from verified card details for nonlands when that would change the recommendation.
- Identify cards that do not serve the primary plan, core support, mana, interaction, or a stated restriction.
- Check claimed combinations using exact Oracle text and `mtg-rules-citations` when a non-obvious rules conclusion is needed.
- For each claimed combo, give prerequisites, ordered actions, result, and disruption point. Call it a synergy if it is not a deterministic winning line.

Do not enforce the upstream “three interactions per nonland” rule mechanically; it rejects necessary lands, efficient staples, and role compression. Explain only material weak links.

### 4. Budget Review

Only run this step when the user sets a budget or asks for prices.

1. Get current prices for high-cost candidates and every card that could plausibly violate a stated per-card cap using `mcp__mtg__get_card_price`.
2. For small/medium budgets, price the complete final list one card at a time only if the user needs a total and the available tool data supports it. State any unpriced cards and do not count them as $0.
3. When pricing materially exceeds the budget, use `mcp__mtg__search_cards` for legal functional alternatives, then retrieve details and current prices for the alternatives.
4. Preserve restrictions and legality; do not silently weaken a theme or add an infinite combo to save money.
5. Re-run full legality after every budget swap.

Completion: report currency, price snapshot caveat, priced/unpriced cards, and whether the total is confirmed, a lower bound, or inconclusive.

## Review / Correction Loop

At most two correction passes per stage by default. Stop earlier when the final legality check passes and remaining concerns are subjective.

- **Legality fail:** mandatory correction and revalidation.
- **Restriction fail:** mandatory correction and revalidation.
- **Structure fail:** offer concrete corrections; do not endlessly optimize against subjective thresholds.
- **Budget unresolved:** ask the user whether to increase budget, relax a stated restriction, or accept a partial/inconclusive price total.

## Required Final Output

1. **Snapshot:** commander(s), strategy, power assumptions, restrictions, and legality status.
2. **Decklist:** plain Moxfield-importable flat list only: quantities and card names, no headings or comments inside the code block.
3. **Validation:** exact result from the final `mcp__mtg__validate_deck` call, including any limitations for unusual command-zone mechanics.
4. **Why it works:** concise role counts and 3–6 key interactions/lines grounded in the final list.
5. **Budget:** only if requested; quote live snapshot source/currency and unresolved values.
6. **Next options:** one short choice—pilot guide, price trimming, collection-only conversion, or alternate power target.

## Common Pitfalls

1. **Using an invalid command zone.** Verify every commander choice; do not treat a legendary creature as automatically compatible with a second commander.
2. **Counting 100 twice.** The MCP deck validator expects the commander separately and a 99-card mainboard.
3. **Conflating price sources.** Do not call a single MCP price result a sealed-precon price, a Card Kingdom price, or a full market survey.
4. **Inventing color identity.** Use the final validator; mana production and card frame do not establish identity.
5. **Applying stale bans/rules.** Retrieve the current ban list and current Oracle text in the task.
6. **Overbuilding the process.** Use delegated reviewer roles when the request merits it; for a quick casual brew, validate rigorously without pretending that eight-agent overhead is necessary.
7. **Claiming collection compliance without checking.** A card being inexpensive or popular does not mean Nico owns it.

## Verification Checklist

- [ ] Commander(s), color identity, and restrictions verified from current card data.
- [ ] Final list has exactly 100 cards including command zone.
- [ ] `mcp__mtg__validate_deck` passes for deck size and singleton; current ban list plus per-card MCP details confirm Commander legality and color identity.
- [ ] Every claimed line uses cards actually in the final list.
- [ ] Material rules claims are backed by current rule/ruling tools.
- [ ] Price claims, if any, identify source/currency and limitations.
- [ ] Decklist is a flat Moxfield-importable list with no comments/categories.
- [ ] Owned-only requirements were checked against supplied verified collection data, or ownership was clearly left unverified.
