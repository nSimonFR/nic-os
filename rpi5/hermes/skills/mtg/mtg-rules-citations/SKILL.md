---
name: mtg-rules-citations
description: Use when answering MTG rules questions with official citations.
version: 1.0.0
author: Nico + Hermes Agent
license: 0BSD
metadata:
  hermes:
    emoji: "⚖️"
    tags: [mtg, magic, rules, rulings, comprehensive-rules, commander]
    related_skills: [mtg-deck-analysis, mtg-commander-strategy]
---

# MTG Rules Citations

## Overview

Answer Magic rules and card-interaction questions using authoritative, current evidence: the Comprehensive Rules glossary/rules and official card rulings exposed through the installed MTG MCP. Give the verdict first, cite the evidence, then name only material edge cases.

Adapted from `dan-blanchard/mtg-skills` `rules-lawyer` (0BSD), using the installed MTG MCP instead of its local `mtg_utils` CLI and downloaded rules/card-data workflow. Source reviewed: https://github.com/dan-blanchard/mtg-skills

## When to Use

- The user asks how cards, keywords, triggers, layers, replacement effects, combat, priority, or Commander rules work.
- A deck review depends on a non-obvious rules interaction.
- The user asks for an official ruling or a Comprehensive Rules citation.

Do not use this skill for informal strategic advice that does not rest on a rules claim.

## Evidence Workflow

1. **Identify the question type.** Determine whether the answer needs a card's Oracle text, a published card ruling, one CR rule, or several interacting rules.
2. **Verify card facts.** Use `mcp__mtg__get_card_details` for exact Oracle text. Use `mcp__mtg__get_card_rulings` for official card-specific rulings.
3. **Locate rule evidence.**
   - Known rule number: `mcp__mtg__get_rule`.
   - Keyword or defined term: `mcp__mtg__get_glossary_term`.
   - Unknown rule or phrase: `mcp__mtg__search_rules` with a narrow query.
4. **Resolve the interaction.** For multi-rule questions, collect every load-bearing rule before reaching a conclusion. Keep dependencies explicit: identify which event happens first, whether an effect is triggered/replacement/static, and whose choices apply.
5. **Write the answer.** Use the required structure below. Every cited rule number must appear in the current tool output; never cite from memory.
6. **Stop honestly.** If the available evidence does not settle the case, say what is missing and avoid a confident answer.

## Required Answer Structure

**Verdict:** One direct sentence describing the outcome.

**Evidence:**
- Exact relevant Oracle text or official card ruling, if applicable.
- `CR <number>` with the directly relevant returned text; quote only what is needed.

**Edge case:** Only conditions that would change the result. Omit generic caveats.

For a simple keyword question, use the glossary and linked rule. For a card-specific question, lead with card rulings and use CR text to resolve any gap.

## Commander-Specific Checks

When relevant, verify rather than assume:

- Color identity and format legality.
- Commander-zone casting, replacement effects, and commander tax.
- Multiplayer targeting/attack restrictions and teammate/opponent wording.
- Partner, Background, Doctor's companion, Friends forever, and choose-a-Background deck-construction rules.
- Commander damage, shared life totals, and variant rules only when the user specifies the variant.

## Common Pitfalls

1. **Answering from training memory.** Use the MCP even if the answer seems obvious.
2. **Citing a rule number without returned text.** Search or retrieve it first.
3. **Confusing Oracle text with a ruling.** Oracle text establishes the card; rulings clarify common applications.
4. **Treating a search snippet as complete proof.** Open the specific rule when its details matter.
5. **Mixing formats.** Do not import Arena, Two-Headed Giant, Planechase, or house-rule assumptions into ordinary Commander.
6. **Overloading the answer.** Cite the rules that decide this question, not every possibly related rule.

## Verification Checklist

- [ ] Exact cards and current Oracle text verified where relevant.
- [ ] All material rule numbers retrieved in the current task.
- [ ] Verdict follows from the cited text and the stated game state.
- [ ] Format/variant assumptions are explicit when they matter.
- [ ] No uncited remembered rules, card text, or invented rulings remain.
