# Synergy Scoring

Use this when selecting themed adds. Structural slots—lands, generic ramp, broad removal, board wipes—are exempt, though a synergistic version wins when equally effective.

## Loop: read → extract → search → intersect → score

1. Retrieve exact Oracle text/type for the commander and relevant engine cards with `mcp__mtg__get_card_details`.
2. Extract the deck’s actionable vocabulary: triggers, conditions, actions, types, keywords, and board axes. Examples: dies, sacrifice, tokens, ETB, artifacts, +1/+1 counters, recursion, lifegain.
3. Search Commander-legal candidates with `mcp__mtg__search_cards`. Use precise Scryfall syntax and `id<=<identity>`—not `c:`—for color-identity filtering. Combine relevant Oracle/type/keyword terms to find intersections.
4. Read shortlisted candidates’ exact details. Count distinct points of contact:
   - +1 for each deck-vocabulary element it supports;
   - +1 when it materially improves a specific existing engine/card.
5. Prefer themed cards with ≥2 points of contact. State those contacts in the recommendation. A one-contact goodstuff card is a likely cut unless it fills a necessary structural role.

## Examples

For a sacrifice/death/token commander, candidate contacts can include token production, sacrifice outlet, death payoff, recursion, and card advantage. A card making tokens when it dies can score three contacts: fodder, death trigger, and recurring sacrifice value.

When several candidates fill the same role, choose the denser legal option that meets the budget and target power. Do not claim a combo until its exact Oracle text, prerequisites, ordered actions, and outcome are verified.

## Check

- [ ] Commander/engine text was retrieved, not remembered.
- [ ] Candidate queries use Commander color identity.
- [ ] Themed additions state at least two concrete contacts or are identified as structural exceptions.
- [ ] Every claimed interaction is checked through `mtg-rules-citations` when non-obvious.
