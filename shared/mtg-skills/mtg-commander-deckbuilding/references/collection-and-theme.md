# Collection constraints and thematic builds

Consolidates the locally retained `mtg-deck-analysis`,
`mtg-collection-deckbuilding`, and `mtg-commander-collection-review` workflows.
The current skill's MCP-only card research and final legality gates take
precedence over their legacy direct-Scryfall recipes.

## Source and availability ledger

1. When the user requests Moxfield-only data, fetch supplied public decks through
   the MTG MCP and use a supplied readable collection export. Do not substitute
   ShowMyCards. If explicitly asked for ShowMyCards links, keep that verification
   separate from the collection source.
2. The local export convention is `/mnt/data/cloud/DOCUMENTS/MAGIC/moxfield_haves_*.csv`.
   Inspect available exports and use the newest relevant one; disclose a missing
   or unreadable export rather than implying private Moxfield access.
3. Parse actual headers such as `Count`, `Name`, `Edition`, `Collector Number`,
   `Foil`, and `Tags`. Binder/location exclusions require an actual populated
   field; a public deck or CSV without one cannot prove them.
4. Distinguish **name exclusion** from **copy reservation**. “Exclude all cards
   from this deck” excludes names from every populated board, including basics.
   Reserving physical copies instead subtracts quantities from collection counts.
   For that ledger, include mainboard/command zone by default; include sideboard
   and maybeboard when the user asks to reserve all cards/the whole deck.
5. Build `available = owned − explicitly reserved copies` per card. Include the
   commander; verify every proposed quantity is within availability. Do not
   mistake owning multiple copies for a singleton exception. Verify any actual
   deck-construction exception through exact Oracle text and rules.
6. Before final delivery, check size, legality, availability, and every name-based
   exclusion independently. If strict exclusion makes a legal deck impossible,
   report it and offer copy reservation as a distinct alternative.

## Card research and recommendations

- Use MCP card search/details, not the legacy direct Scryfall batch scripts.
  An incomplete candidate search is not an exhaustive collection audit.
- Rank by the commander's plan and concrete roles, not raw popularity. Separate
  strong includes, playable filler, and poor fits; distinguish owned cards from
  wishlist candidates. Return the requested number when evidence supports it.
- Do not reuse old session-specific ownership lists or card interpretations as
  current facts. Verify Oracle text and rules: a continuous Aura bonus is not a
  +1/+1 counter; bestow and normal Auras have different failure modes.
- For budget searches narrowed by era/rarity, state the set range and search the
  intervening sets rather than treating core sets as the entire period.

## Theme and numbered-option verification

- Resolve a numbered option from the actual earlier message/history before
  building around it. If unavailable, ask for its wording rather than assigning
  the number to a different idea.
- Establish whether the theme constrains characters, particular permanent types,
  or artwork on every nonland. Confirm whether owned/current cards take priority.
- Do not infer gender from a card name or creature type. Verify the exact
  printing/artwork before claiming art compliance. If the available tools cannot
  show the relevant art, label candidates unverified and request evidence.
- Preserve a coherent engine. For commanders with tap abilities, evaluate haste,
  untapping, and protection rather than treating the commander as incidental.

## Popularity and sealed-product caveats

Ranks and deck counts require a current source; distinguish a partner pair from
an individual commander. The installed MCP does not guarantee rank snapshots,
precon associations, or sealed-product market prices. Report that limitation when
those data are unavailable. Never substitute a singles total for a sealed precon
price, or fabricate an average from selected published deck examples.
