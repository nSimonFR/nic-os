---
name: populartimes
description: Live and weekly Google popular times (busyness, "fréquentation", "affluence") for a place, e.g. is the climbing gym crowded right now.
version: 2.0.0
metadata:
  hermes:
    tags: [google-maps, places, popularity, busy-times, affluence]
    category: productivity
    requires_toolsets: [terminal]
    requires:
      bins: [populartimes-query]
      env: [SERPAPI_API_KEY]
---

# Popular Times

`populartimes-query` reads the "Horaires d'affluence" block of Google Search's
place panel through SerpApi. Values are relative busyness, 0–100, not head counts.

```bash
populartimes-query "Arkose Chevaleret Paris"            # live + today
populartimes-query --day saturday "Arkose Chevaleret Paris"
populartimes-query --day all "Arkose Chevaleret Paris"  # whole week
populartimes-query --quota                              # searches left, free
```

Output: `Live: <Google's text> (<score>/100)`, then `<day>: 07h=9 08h=12 …`.
Compare the live score to the same hour's usual value to say busier/quieter than usual.

Traps:
- The query is a Google search: name + city (or street) so the panel is the right
  place. If it says "No Google knowledge panel", retry once with the address
  (`goplaces resolve "<name>" --json` gives it); don't loop.
- No `Live:` score means closed or no live data right now; fall back to the
  usual value for the current hour and say so.
- Free plan: 250 searches/month, each call spends one. Don't poll or batch; one
  call per question. If `--quota` is low, tell Nico.
- Never ask for the key in chat: `SERPAPI_API_KEY` is Agent Vault's placeholder.
