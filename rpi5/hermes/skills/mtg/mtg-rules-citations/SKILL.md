---
name: mtg-rules-citations
description: Use when answering MTG rules questions with current official citations.
version: 1.1.0
author: Nico + Hermes Agent
license: 0BSD
metadata:
  hermes:
    emoji: "⚖️"
    tags: [mtg, magic, rules, rulings, comprehensive-rules, commander]
    related_skills: [mtg-commander-deckbuilding, mtg-commander-strategy]
---

# MTG Rules Citations

Answer rules or card-interaction questions with current Oracle text, official rulings, and Comprehensive Rules evidence. Give the verdict first, then only the evidence that decides it.

0BSD adaptation of `dan-blanchard/mtg-skills` `rules-lawyer`, using installed MTG MCP tools rather than local scripts/downloaded data. Source: https://github.com/dan-blanchard/mtg-skills

## When to Use

- A user asks how cards, keywords, timing, layers, replacement effects, combat, or Commander rules work.
- A deckbuilding or pilot recommendation depends on a non-obvious mechanical claim.

Do not use for ordinary strategic advice with no rules conclusion.

## Evidence Loop

1. Get exact relevant Oracle text: `mcp__mtg__get_card_details`.
2. Get card-specific published rulings when useful: `mcp__mtg__get_card_rulings`.
3. Get rules evidence:
   - known number: `mcp__mtg__get_rule`;
   - defined term/keyword: `mcp__mtg__get_glossary_term`;
   - unknown rule: `mcp__mtg__search_rules`, then retrieve the decisive rule.
4. For interacting effects, establish event order, effect type (triggered/replacement/static), choices, and every load-bearing rule before concluding.
5. If evidence is insufficient, say so. Never cite rule numbers, Oracle text, or rulings from memory.

## Answer Format

**Verdict:** direct outcome.

**Evidence:** relevant Oracle text/ruling and `CR <number>` with only the deciding text.

**Edge case:** only a condition that changes the result.

EDHREC is never rules proof. MCP resource summaries are orientation only; do not cite them as current authority for format procedures (especially mulligans) without targeted current rule/ruling evidence.

## Commander Notes

When relevant, verify command-zone casting/replacement, color identity, commander damage, multiplayer wording, and special command-zone permissions (Partner, Background, Doctor’s companion, Friends forever). Deck legality validation belongs to `mtg-commander-deckbuilding`.

## Checklist

- [ ] Exact cards and current Oracle text checked.
- [ ] Each material rule number/ruling came from current tool output.
- [ ] Verdict follows from the stated game state.
- [ ] Format/variant assumptions are explicit when material.
- [ ] No remembered or invented citation remains.
