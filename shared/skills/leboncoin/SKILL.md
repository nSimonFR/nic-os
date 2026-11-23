---
name: leboncoin
description: Search leboncoin (LBC) listings, spot price errors and mislisted ads, message sellers and negotiate politely, then monitor replies and new ads on a schedule. Use for "cherche sur leboncoin", "négocie cette annonce", "surveille les nouvelles annonces", or any leboncoin buying task.
---

# leboncoin

Session: `transfer-cookie` into a fresh `profileId: "incognito"` tab (Zen default container, `--context ''`). The `datadome` cookie is what DataDome checks: a captcha means copy a fresh one from Zen and set it from any `www.leboncoin.fr` page. Login cookies last 24 h in the copy: re-run when `/messages` redirects to `auth.leboncoin.fr`.

## Discover
- Search: `/recherche?text=…&category=43` (consoles; `15` ordinateurs), `&locations=Paris_75013,Paris_75005`, `&price=a-b`, `&sort=time|price&order=asc|desc`, `&page=N`. OR is unsupported: one query per spelling.
- Parse `__NEXT_DATA__` from the HTML: search → `props.pageProps.searchData.ads` (`list_id`, `subject`, `price[0]`, `location.city/region_name`, `first_publication_date`, `attributes` incl. `shippable`); ad → `props.pageProps.ad`. Link: `/ad/<category>/<list_id>`.
- Price errors: group ads by exact variant (model, capacity), take the median of 20+, flag below p25 minus 30 %. Mislisted ads: query typos, wrong category, wrong brand field; read the description, a wrong-category listing is often the best deal.

## Contact and negotiate
- First message: `/reply/<list_id>`, set `textarea[name=body]` with the native value setter plus an `input` event, click `Envoyer`; the URL becomes `/reply/success/…`. Inside a thread (`/messages/id/<uuid>`): `textarea[placeholder="Écrivez votre message"]`, button `Envoyer mon message`. "Votre vendeur peut être moins réactif" is a system message, not a reply.
- One ceiling per variant, set by the user. Ask availability first; open at 70–75 % of the ask with a reason (immediate payment, comparing several); climb in small steps, one named final offer at the ceiling; answer every seller reply.
- A seller at or under the ceiling means notify the user and wait: the user pays, books the meeting, and decides. Never pay, accept a meeting, share a phone number or address, or leave LBC's secure payment; an external link, WhatsApp or off-LBC payment is a scam signal.
- Close politely when the seller holds firm or turns rude: thank, wish a good sale, leave the door open at the last offer. Delete closed threads (`Plus d’options` → `Supprimer la conversation` → `Supprimer`, one per pass).

## Pace and monitor
- DataDome blocks bursts (it "slows you down" after a few dozen actions an hour). Per pass: one search scan (page 1, then further pages only while every ad is newer than the checkpoint), 20–60 s random pauses between fetches, navigations and sends, 6–12 s before reading a page, each `preview_evaluate` under ~12 s (put long waits in Bash). On a captcha or 403: stop, tell the user, wait for a fresh cookie.
- Schedule with `schedule_task` every 2 h, a night guard at the top of the prompt (`TZ=Europe/Paris date +%H`), state in one scratchpad file (rules, table of ads/threads/ceilings, and one last-check timestamp per search). Monitor searches use `sort=time&order=desc`; an ad is new when its `list_id` is not yet in the table. Every pass restarts at page 1 (listings that vanish between passes shift pages, so a stored page number would skip ads) and reads on page by page until a whole page is at or before the checkpoint or comes back empty (a boosted "Tête de liste" ad can sit above newer ones, so one old ad never ends the scan); then the checkpoint moves to the newest `first_publication_date` seen on page 1 minus a 6 h overlap (search results have no stable cursor: the overlap re-reads the recent tail so an ad shifted by a removal mid-scan is caught next pass, and `list_id` dedupe absorbs the repeats); an empty search leaves it unchanged. New ads join the table and are reported; contact sellers automatically only when the user authorised it. Alert the user (Telegram + thread) only for a deal, a proposed meeting, a scam, or a block; otherwise one summary line and snooze to the next pass. Delete the task once every purchase it covers is done, or when the user asks.
