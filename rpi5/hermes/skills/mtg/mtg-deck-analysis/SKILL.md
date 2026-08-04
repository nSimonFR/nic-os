---
name: mtg-deck-analysis
description: Use when analyzing Magic decks or Moxfield collections.
metadata:
  hermes:
    emoji: "🃏"
    related_skills: [mtg-commander-strategy, mtg-rules-citations]
---

# MTG deck analysis and Moxfield exports

Use for Magic: The Gathering deck reviews, Commander upgrade recommendations, Moxfield deck retrieval, or comparing decks against the user's owned-card collection.

## Workflow

1. Retrieve the deck from its public Moxfield URL. Extract its public ID.
2. Fetch the public deck JSON using the Moxfield API method in `references/moxfield-public-api.md`.
3. Verify the response before analyzing: deck name, format, commander, color identity, 99-card mainboard, and timestamp.
4. Save an indented JSON export locally before review. Copy it to the user-designated archive only after confirming write permission.
5. Review deck structure: land count, color sources/fixing, ramp, card draw, removal, protection, mana curve, and how well cards serve the commander’s plan.
6. When an owned-card CSV is supplied, compare proposed additions against it and explicitly check Commander color identity/legality. Do not recommend off-color cards just because the user owns them.
7. For a requested full rebuild, output a complete Moxfield-importable list, not only a swap package. It must be exactly 100 cards including the commander (99 in the validation decklist parameter), singleton, legal for the commander’s color identity, and every nonbasic card must be verified against the owned collection when the rebuild is collection-only. Save the text import file and attach it.
8. Give a concise, prioritized package: diagnosis, strongest owned-card additions, first cuts, a concrete swap list, and optional future purchases.

## Commander review heuristics

- For a typical three-color casual Commander deck, flag land counts below 35; 36–37 is a usual starting target unless the deck has unusually dense, cheap ramp.
- Distinguish cards that advance the primary plan from isolated mini-themes or limited-style filler.
- Prefer permanent, repeatable sources of draw/ramp/interaction over one-shot combat tricks unless combat tricks are central to the commander.
- Identify synergy conflicts (e.g. graveyard hate versus the deck's recursion package).
- State uncertainty where power target, budget, or playgroup is unknown; avoid presenting subjective card choices as facts.

## Output for Telegram

Telegram Rich Messages are a Bot API feature, not ordinary Telegram Markdown. When the delivery path exposes a native rich-message send action, send the finished review through `sendRichMessage` using `InputRichMessage` (`markdown`, `html`, or explicit `blocks`). It supports headings, tables, task lists, quotations, collapsible details, and media. Do not confuse it with `InlineQueryResultArticle`, standard `sendMessage`, or merely emitting Markdown.

Before saying a review was sent as a Rich Message, verify that the channel adapter actually called the native rich-message endpoint and that delivery succeeded. If the available delivery surface only accepts normal assistant text, say plainly that it cannot produce a native Rich Message; do not imitate it with Markdown and claim equivalence.

For mobile readability, use a short hierarchy such as `## Snapshot`, `## What works`, `## Problems`, `## Changes`, `## Future upgrades`. Use tables only when they materially improve comparison (e.g. add/cut mapping); otherwise prefer short bullets. Use inline code for card names and keep swap lists numbered.

## Thematic Commander rebuilds

When a user asks to rebuild around a theme plus a mechanical plan (for example, a character-focused deck that gains life), establish the theme boundary before proposing a full swap package:

1. Ask whether the restriction applies to **game objects** (such as creatures and planeswalkers), all named characters, or the illustration of every nonland card where a relevant printing exists.
2. Ask whether to prioritize cards already in the current deck / owned collection before recommending purchases. If a budget matters and is unknown, present additions as an unpriced shortlist rather than implying affordability.
3. Preserve a coherent mechanical core: state the commander’s role, life-gain enablers, payoffs, card advantage, protection, ramp, interaction, and realistic win conditions.
4. For a commander with a tap ability that remains tapped (such as `Rubinia Soulsinger`), specifically assess untap effects, haste, and protection as a support package rather than treating the commander as incidental removal.
5. Keep only on-theme current cards that also materially support the new game plan; identify low-impact Limited filler and one-shot combat tricks as early cuts.

### Art and gender-theme verification

Do not infer a character’s gender from creature type, flavor, or a card name. For any recommendation claimed to meet a woman/female-presenting character or art restriction, verify the exact card/printing’s name, Oracle identity where applicable, and artwork before labeling it compliant. Distinguish clearly between:

- **Character restriction:** cards whose depicted/named principal character is a woman/female-presenting character;
- **Game-piece restriction:** only specified permanent types (commonly creatures and planeswalkers) must comply;
- **Artwork restriction:** each nonland card must use a specific compliant printing.

Artwork-specific themes require a final printings pass; deck APIs usually identify a printing but do not reliably establish who is depicted. Never claim full art compliance without that check. Use precise language such as “candidate subject to printing-art verification” while it remains unverified.

## Budget-upgrade research

When the user asks for cheap upgrades, group recommendations by function: sacrifice outlets, recurring fodder, death payoffs, draw, ramp, and commander protection. Check live prices before quoting them and label them as reference prices that vary by printing, condition, and seller. Verify Commander color identity and exact Oracle text.

If the user narrows the search by era or rarity, state the set range explicitly and query the intervening sets rather than treating core sets as the entire period. For sacrifice/counters decks, prioritize repeatable fodder, free sacrifice outlets, and cards that convert deaths into cards, mana, or damage. Do not recommend limited-format filler merely because it matches a keyword.

## References

- `references/moxfield-public-api.md` — verified public-deck endpoint and export procedure.
