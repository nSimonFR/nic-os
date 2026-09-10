# Immich WhatsApp UUID Archive Audit

## Workflow

- Workflow: `ef9b3c99-b034-42ed-a98b-484926266385`
- Trigger: `AssetCreate`
- Expected physical `plugin_method` order: `assetFileFilter`, then `assetArchive`.
- Filter config:
  ```json
  {"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.","matchType":"regex","caseSensitive":false}
  ```
- Expected steps: both enabled; filter logical order `0`, archive logical order `1`.

**Critical:** runtime executes in physical `plugin_method` row (`ctid`) order. If archive precedes filter, it runs unconditionally. Check first:

```sql
SELECT name FROM plugin_method
WHERE name IN ('assetFileFilter','assetArchive')
ORDER BY ctid;
```

On inversion, disable the workflow through
`PUT /api/workflows/<id> {"enabled":false}` only if the current audit has explicit
user authorization for that incident response. This reference is not itself an
authorization. Otherwise report and request approval. After an authorized change,
verify the disabled state, report loudly, and enumerate the recent archive window.
Never auto-unarchive on this path.

## Data sources

- WhatsApp album: `e5a36785-5742-43f5-81ab-28f4ffd18c4e`
- Recently Saved album: `53b5d2a2-4524-4f4a-bfdc-be7820a73325`
- Archived assets: `asset.visibility = 'archive'`
- Asset EXIF: `asset_exif` joined on `assetId`
- Album membership: `album_asset` joined on `assetId`
- Curated albums: any membership except `Recents`, `Recently Saved`, or names beginning `[AUTO]`.

## Candidate classification

Do **not** call the count of UUID-named archived files absent from the current WhatsApp
album a false-positive count: the album is a current-device snapshot.

Exclude from alerting:

- normal high-volume WhatsApp import bursts;
- no-EXIF UUID media whose capture date is far earlier than upload (source signature).

Alert when a candidate is in a curated album, has a non-phone camera (`SONY`, `NIKON`,
`FUJIFILM`, `Canon`, scanner), or is `iPhone 16` family (the owner’s phone is iPhone 11
Pro, so this is ambiguous / potentially received WhatsApp media and must be labelled as
such).

## Volume baseline

Compare the active week to the preceding eight full weekly buckets. Use their median
and an absolute minimum: alert when current count is at least `max(20, 3 × median)`.
State both current volume and median.

## Delivery

Normal outcome is silence. Direct Telegram HTML only for an incident, one or more
reportable candidates (default threshold `1`), or a volume spike. Dynamic filenames and
album names must be HTML-escaped; photo links use:

`https://rpi5.gate-mintaka.ts.net:10000/photos/<asset-id>`
