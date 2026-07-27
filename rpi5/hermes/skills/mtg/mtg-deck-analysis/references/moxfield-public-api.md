# Moxfield public-deck retrieval

For a public Moxfield URL `https://moxfield.com/decks/<PUBLIC_ID>`, retrieve the full deck JSON with:

```sh
curl --location \
  --user-agent 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36' \
  --header 'Accept: application/json' \
  --header 'x-moxfield-version: 2026.7.1' \
  "https://api2.moxfield.com/v3/decks/all/<PUBLIC_ID>"
```

The normal page is JavaScript-rendered; direct scraping may yield only a loading page. This public API endpoint returned complete deck data for public decks in this session.

## Verify

Confirm HTTP 200 and JSON fields:

- `name`, `format`, `publicUrl`, `publicId`
- `main.name` (Commander)
- `colorIdentity`
- `boards.mainboard.count` (normally 99 for Commander)
- `lastUpdatedAtUtc`

## Export

Save formatted JSON with a stable filename such as:

`<slugified-deck-name>--<public-id>.json`

If archiving to a user cloud folder, test directory write access first. Do not claim the export is archived until the copy and a readback/byte comparison succeed.
