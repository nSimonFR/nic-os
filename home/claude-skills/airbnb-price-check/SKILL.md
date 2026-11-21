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
   -15 % ≤3 d) are in the Hermes `airbnb-pricing` skill's `rules.json`.

2. **Market, no login.** `preview_open` with `profileId: "default"`, then `fetch` from the page:
   `/s/Paris-20e-Arrondissement--France/homes?checkin=D1&checkout=D2&adults=2&currency=EUR&room_types[]=Entire home/apt&min_bedrooms=1&min_beds=1`
   (2-night stays, one midweek and one Fri/Sat per gap). In `<script id="data-deferred-state-0">`
   take nodes with `structuredDisplayPrice` + `demandStayListing`; nightly = the "N nights x €X"
   item of `explanationData.priceDetails`; id = `atob(demandStayListing.id).split(':')[1]`.
   Keep 1-bedroom, ≥4.85 with ≥5 reviews or Guest favorite, de-duplicate by id, report
   n / p25 / median / p75.
   Traps: logged in as host, your own listing is hidden from search. Guest nightly ≈ host
   calendar price + 12 €: compare on guest, type host.

3. **Decide.** Aim near the median for a Guest favorite, weekend +10 %. Cut only while nights
   are open and the ladder says so, never below the floor.

4. **Apply (ask first).** `transfer-cookie` (Zen) into an **incognito** tab, delete the cookie
   files after. One range per call:
   `https://www.airbnb.com/multicalendar/<id>/edit-selected-dates/<from>/<to>/nightly-price`
   Then in `preview_evaluate`: set `#PriceInput-nightlyPrice` (native value setter + `input`
   event), DOM-click the `Save` button, wait 3 s, read the day buttons back. A mixed-price range
   shows a "€a - €b" button: click it first. `preview_act type` and a real click on Save fail.
   Verify by re-running step 2. `preview_snapshot` can time out: read the DOM.

5. **Daily check.** `CronCreate` (session-only, 7-day expiry), off-minute like `7 9 * * *`:
   steps 1-3 read-only, ≤6 lines, "No cut needed today" or exact host prices, then ask. For one
   that outlives the session, extend the Hermes `airbnb-pricing` cron.
