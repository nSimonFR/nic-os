---
name: airbnb-price-check
description: Compare a host's Airbnb nightly prices with similar listings, optimize them, apply them in the host calendar, and set up a daily "do we need to lower prices" check. Use when asked to check, compare, optimize or lower Airbnb prices, or to apply a discount to the calendar.
---

# Airbnb price check

Airbnb has no host API. Read the market anonymously, edit the calendar through the
logged-in web UI (T3 preview tools). Listing id: from the host calendar URL
`/multicalendar/<id>`; facts about the flat live in the `airbnb-hosting-ops` and
`airbnb-pricing` memories (rules, cap, fees).

## 1. Own facts

`ssh rpi5 '~/.hermes/scripts/airbnb-pricing.sh --no-state --force'` → open gaps with
`lead_days`, the 90-night cap, booking mismatch. Rules: `rules.json` in the Hermes
`airbnb-pricing` skill (floors, lead-time ladder -5 % ≤14 d, -10 % ≤7 d, -15 % ≤3 d).

## 2. Market (no login)

`preview_open` with `profileId: "default"`, then `preview_evaluate` a `fetch` per window:

`/s/Paris-20e-Arrondissement--France/homes?checkin=D1&checkout=D2&adults=2&currency=EUR&room_types[]=Entire home/apt&min_bedrooms=1&min_beds=1`

Parse `<script id="data-deferred-state-0">` JSON, walk to nodes holding both
`structuredDisplayPrice` and `demandStayListing`. Nightly = `explanationData.priceDetails[].items`
entry "N nights x €X"; id = `atob(demandStayListing.id).split(':')[1]`; bedrooms/rating from
`structuredContent` and `avgRatingLocalized`. Keep 1-bedroom, rating ≥4.85 with ≥5 reviews
or Guest favorite, de-duplicate by id (carousels repeat), report n, p25, median, p75.
Use 2-night stays, one midweek and one Fri/Sat pair per gap.

Traps: logged in as the host, your own listing is hidden from search: read it anonymously.
Search nightly (guest side) ≈ calendar host price + 12 €: convert before typing prices.
Compare on the guest figure, enter the host figure.

## 3. Decide

Target the comps median ± a little for a Guest favorite; hold weekend premium near +10 %.
A cut only while nights are open and the ladder says so; never below the floor. Unsold
nights are lost when the cap is not binding, so lean to cutting late, not early.

## 4. Apply (needs the user's go)

Log in with `transfer-cookie` (Zen) into an **incognito** tab; delete the cookie scratch
files afterwards. Edit by URL, one range per call:

`https://www.airbnb.com/multicalendar/<id>/edit-selected-dates/<from>/<to>/nightly-price`

then in `preview_evaluate`: set `#PriceInput-nightlyPrice` with the native value setter
plus an `input` event, click the button whose text is `Save`, wait 3 s, read the day
cells back (`button` `innerText` "Nightly price €X"). A range with mixed prices shows a
"€a - €b" button first: click it to reveal the input. `preview_act type` and a real click
on Save did not work here; DOM clicks did. Blocked dates are left alone. Airbnb may store
€1 under the typed value on Sat/Sun.

Verify afterwards: re-run step 2 anonymously and compare your guest nightly with the
targets. `preview_snapshot` may time out on hidden tabs; read the DOM instead.

## 5. Daily check

`CronCreate` (session-only, dies with the session, expires after 7 days) at an off-minute
such as `7 9 * * *`. Prompt: steps 1-3 read-only, report ≤6 lines, "No cut needed today"
or exact host prices, then ask before applying. For a check that survives the session,
extend the Hermes `airbnb-pricing` cron instead.
