---
name: airbnb-price-check
description: Compare a host's Airbnb nightly prices with similar listings, apply new prices in the host calendar, and run a daily "lower prices?" check. Use when asked to check, compare, optimize or lower Airbnb prices.
---

# Airbnb price check

No host API: read the market anonymously, edit the calendar through the web UI (T3 preview
tools). Listing id = `/multicalendar/<id>` in the host calendar URL; flat facts in the
`airbnb-hosting-ops` and `airbnb-pricing` memories.

1. **Own facts.** `ssh rpi5 '~/.hermes/scripts/airbnb-pricing.sh --no-state --force'`: open
   gaps with `lead_days`, 90-night cap. Floors and lead-time ladder (-5 % ≤14 d, -10 % ≤7 d,
   -15 % ≤3 d) are in the Hermes `airbnb-pricing` skill's `rules.json`. The script's
   `prices` are rule output, not the live calendar. Any proposal is provisional: the cut test
   is per night against its own calendar price (step 4, and the daily check in step 5); our
   step 2 card is a 2-night average and says nothing about one night.

2. **Market, no login.** `preview_open` with `profileId: "default"`, then `fetch` from the page:
   `/s/Paris-20e-Arrondissement--France/homes?checkin=D1&checkout=D2&adults=2&currency=EUR&room_types[]=Entire home/apt&min_bedrooms=1&min_beds=1`
   (2-night stays, a midweek and a Fri/Sat one per gap where they fit; say when a gap
   is too short for the weekend comparison). In `<script id="data-deferred-state-0">`
   take nodes with `structuredDisplayPrice` + `demandStayListing`; nightly = the "N nights x €X"
   item of `explanationData.priceDetails`; id = `atob(demandStayListing.id).split(':')[1]`.
   Keep 1-bedroom, ≥4.85 with ≥5 reviews or Guest favorite, de-duplicate by id, report
   n / p25 / median / p75.
   Traps: logged in as host, your own listing is hidden from search. Guest nightly ≈ host
   calendar price + 12 €: compare on guest, type host.

3. **Decide.** Aim near the median for a Guest favorite, weekend +10 %. Cut only while nights
   are open and the ladder says so, never below the floor. Cap binding: hold, no cut.
   Gap with `bookable_at_min_stay: false`: no cut (a lower price can't fit the minimum
   stay), list it in the report and propose the min-stay change separately.

4. **Apply (ask first).** `transfer-cookie` (Zen) into an **incognito** tab, delete the cookie
   files after. Before any edit read each night's own calendar price (day buttons, "Nightly
   price €X"): keep a night only if the proposed price is lower than it; skip the rest,
   including a night with no readable price. Edit the kept nights, one range per call:
   `https://www.airbnb.com/multicalendar/<id>/edit-selected-dates/<from>/<to>/nightly-price`
   Then in `preview_evaluate`: set `#PriceInput-nightlyPrice` (native value setter + `input`
   event), DOM-click the `Save` button, wait 3 s, read the day buttons back. A mixed-price range
   shows a "€a - €b" button: click it first. `preview_act type` and a real click on Save fail.
   Read back every night; a night that can't be read back has failed, never passed: report
   it as unverified (the price may sit below the floor). Any mismatch with the typed price
   (Airbnb can store a Sat/Sun €1 under, or Save can fail and leave the old price), or a
   night below the floor, gets one
   re-edit and a new readback; if it still differs, report it, and if it is still below the
   floor put back the price read before the edit and read it back (urgent report if the
   restore fails, reads back different, or can't be read). Then re-run step 2.
   `preview_snapshot` can time out: read the DOM.

5. **Daily check.** `CronCreate` (session-only, 7-day expiry), off-minute like `7 9 * * *`:
   steps 1-3 plus step 4's per-night calendar read (read-only, no edit; needs the Zen login:
   a night whose calendar price can't be read is "unverified": no cut proposed for it, and
   never "No cut needed"), ≤6 lines, "No cut needed today" only when every night is
   verified, else exact host prices for the verified nights, then ask. For one that outlives the session, extend the Hermes `airbnb-pricing` cron.
