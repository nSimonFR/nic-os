# OSXPhotos - CLI tool for Apple Photos

Installed via Homebrew tap `RhetTbull/osxphotos` (declared in `macos/components/homebrew.nix`).

- **Version:** 0.75.6
- **Docs:** https://rhettbull.github.io/osxphotos/
- **Repo:** https://github.com/RhetTbull/osxphotos

## Library stats (as of 2026-03-10)

```
Photos library: ~/Pictures/Photos Library.photoslibrary
Total: 5212 assets (4697 photos, 515 videos)
Visible in app: 4473 (4255 iCloud-only, not downloaded locally)
Named persons: 12 | Albums: 5 | Shared albums: 12
Favorites: 20 | Edited: 239 | In trash: 33
```

---

## Commands overview

| Command | Description |
|---------|-------------|
| `query` | Search photos with powerful filters (person, date, label, location, keyword, album, favorites, duplicates, etc.) |
| `export` | Export photos with full metadata, sidecars, live photos, bursts, RAW. Supports templates for filenames/directories |
| `import` | Import photos/videos into Photos, preserves edits (.AAE), live photos, bursts, RAW+JPEG pairs |
| `batch-edit` | Edit metadata: title, description, keywords, location, favorite, add-to-album. Supports `--undo` |
| `timewarp` | Adjust date/time/timezone. Parse dates from filenames, push/pull EXIF, reset to originals |
| `sync` | Sync metadata & albums between two Photos libraries (e.g. iPhone <-> Mac) |
| `add-locations` | Fill missing GPS data from nearest-neighbor photos within a time window |
| `push-exif` | Write Photos metadata back to original files' EXIF |
| `compare` | Diff two Photos libraries |
| `dump` | Full JSON metadata dump of all photos |
| `inspect` | Interactive inspector for selected photos |
| `repl` | Python REPL with full PhotoInfo API access |
| `orphans` | Find orphaned files in the library |
| `labels` | List all AI classification labels |
| `albums` / `keywords` / `persons` / `places` | List those respective entities |
| `show` | Open a photo/album in Photos by UUID or name |
| `snap` / `diff` | Snapshot DB state and diff between snapshots |
| `grep` | Search the Photos sqlite database directly |

## Limitations

- **No delete** - cannot delete/trash photos (use Photos.app or AppleScript)
- **No face tagging** - can't assign names to faces
- **AI labels are read-only** - Apple ML labels (beach, food, etc.) can be queried but not modified
- **iCloud EXIF sync** - `push-exif` won't propagate changes via iCloud to other devices

---

## iCloud Photos cleanup plan

osxphotos can't delete photos directly, but it can **identify cleanup candidates and collect them into temporary albums** for manual review and deletion in Photos.app.

### Cleanup candidates (current library)

| Category | Count | Why delete? |
|----------|------:|-------------|
| Duplicates | 38 | Exact copies wasting space |
| Screenshots | 165 | Usually temporary/disposable |
| Screen recordings | 8 | Usually temporary |
| Burst photos | 19 | Keep picks, delete the rest |
| Documents/scans | 693 | Often one-time captures (receipts, menus, tickets, etc.) |
| Large files >50MB | 116 | Review large videos |
| Large files >20MB | 220 | Review if needed |
| Already in trash | 33 | Empty trash to reclaim immediately |

Document sub-categories: Printed Page (103), Handwriting (73), Map (28), Chalkboard (22), Newspaper (21), Whiteboard (20), Chart (20), Receipt (11), Ticket (11), Menu (10), Boarding Pass (8), Computer Program (8), Barcode (3).

### Step 1: Create cleanup albums

```sh
# Duplicates
osxphotos query --duplicate --add-to-album "zz-cleanup/Duplicates"

# Screenshots & screen recordings
osxphotos query --screenshot --add-to-album "zz-cleanup/Screenshots"
osxphotos query --screen-recording --add-to-album "zz-cleanup/Screen Recordings"

# Burst photos
osxphotos query --burst --add-to-album "zz-cleanup/Bursts"

# Documents & scans (review - some may be worth keeping)
osxphotos query --label "Document" --add-to-album "zz-cleanup/Documents"
osxphotos query --label "Receipt" --add-to-album "zz-cleanup/Receipts & Tickets"
osxphotos query --label "Ticket" --add-to-album "zz-cleanup/Receipts & Tickets"
osxphotos query --label "Boarding Pass" --add-to-album "zz-cleanup/Receipts & Tickets"
osxphotos query --label "Menu" --add-to-album "zz-cleanup/Receipts & Tickets"

# Large files (>50MB) for review
osxphotos query --min-size "50MB" --add-to-album "zz-cleanup/Large Files >50MB"
```

### Step 2: Review in Photos.app

1. Open Photos.app
2. Go to each `zz-cleanup/*` album
3. Review contents - select what you want to delete
4. Right-click > Delete (moves to Recently Deleted)
5. Empty Recently Deleted to reclaim iCloud space

### Step 3: Remove cleanup albums

After cleanup, delete the `zz-cleanup` albums from Photos.app (deleting an album doesn't delete the photos in it).

### Tips

- Start with **Screenshots** and **Duplicates** - these are the safest to mass-delete
- **Documents** album needs careful review - some may be important
- **Large Files** are often long videos - biggest space savings per deletion
- Use `--dry-run` with batch-edit commands to preview before changing anything
- The 33 photos already in trash can be purged immediately from Photos > Recently Deleted

---

## Query examples

```sh
# Find all photos of a person
osxphotos query --person "Nicolas Simon"

# Photos from a date range
osxphotos query --from-date 2024-01-01 --to-date 2024-12-31

# Photos added in the last week
osxphotos query --added-in-last "1 week"

# Favorited photos
osxphotos query --favorite

# Search by AI label
osxphotos query --label "beach"

# Find duplicates
osxphotos query --duplicate --count

# Photos with no location
osxphotos query --no-location --count

# Combine filters (AND between different options, OR within same option)
osxphotos query --person "Nicolas Simon" --person "Anne Dolou" --keyword "vacation"

# Custom Python filter
osxphotos query --query-eval "len(photo.persons) > 3"

# Regex on template fields
osxphotos query --regex "^Beach" "{album}"

# JSON output
osxphotos query --person "Nicolas Simon" --json

# Custom field output
osxphotos query --field uuid "{uuid}" --field name "{original_name}" --field title "{title}"

# Print template per photo
osxphotos query --print "{original_name} - {created.date}" --quiet

# Add query results to an album
osxphotos query --from-date 2024-06-01 --to-date 2024-06-30 --add-to-album "June 2024"
```

## Batch edit examples

```sh
# Add keywords to selected photos
osxphotos batch-edit --keyword "Travel" --keyword "Family"

# Replace all keywords
osxphotos batch-edit --keyword "NewTag" --replace-keywords

# Set title with template
osxphotos batch-edit --title "{created.year}-{created.dd}-{created.mm} {counter:03d}"

# Set description from location
osxphotos batch-edit --description "{place.name}"

# Add to album with query filters
osxphotos batch-edit --add-to-album "Best Of 2024" --from-date 2024-01-01 --to-date 2024-12-31 --favorite

# Set/clear favorite
osxphotos batch-edit --set-favorite
osxphotos batch-edit --clear-favorite

# Set GPS location
osxphotos batch-edit --location 48.8566 2.3522

# Dry run
osxphotos batch-edit --keyword "Test" --dry-run --verbose

# Undo last batch edit
osxphotos batch-edit --undo
```

## Export examples

```sh
# Basic export
osxphotos export /path/to/dest

# Export with year/month directory structure
osxphotos export /dest --directory "{created.year}/{created.month}"

# Export only favorites
osxphotos export /dest --favorite

# Export a specific person
osxphotos export /dest --person "Nicolas Simon"

# Export with sidecar files
osxphotos export /dest --sidecar xmp --sidecar json

# Incremental export (only new/changed)
osxphotos export /dest --update

# Export with .AAE files (preserves edits for re-import)
osxphotos export /dest --export-aae
```

## Timewarp examples

```sh
# Set date for selected photos
osxphotos timewarp --date 2024-06-15

# Shift time
osxphotos timewarp --time-delta "-1 hour"

# Set timezone (preserving local time)
osxphotos timewarp --timezone "Europe/Paris" --match-time

# Pull date/time from EXIF
osxphotos timewarp --pull-exif --verbose

# Push Photos date/time to EXIF
osxphotos timewarp --push-exif --verbose

# Reset to original (macOS >= 13)
osxphotos timewarp --reset

# Set "date added" to match photo date (removes from Recents)
osxphotos timewarp --date-added-from-photo

# Inspect date/time/timezone
osxphotos timewarp --inspect
```

## Other useful commands

```sh
# Fill missing location from nearby photos
osxphotos add-locations --window "2 hr" --verbose --dry-run

# Sync metadata between libraries
osxphotos sync --export /shared/mac1.db --merge all --import /shared/mac2.db

# Find orphaned photos
osxphotos orphans

# Library info
osxphotos info

# List all AI labels
osxphotos labels

# Interactive REPL
osxphotos repl

# Show hidden commands
OSXPHOTOS_SHOW_HIDDEN=1 osxphotos help
```
