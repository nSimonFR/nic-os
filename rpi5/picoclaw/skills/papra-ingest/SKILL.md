---
name: papra-ingest
description: File a local document (PDF, image, scan, etc.) into Papra, the self-hosted document archive. The file is queued for ingestion and auto-tagged on-prem (French). Use when the user wants to add, save, file, or archive a document into Papra.
homepage: https://papra.app
metadata: {"openclaw":{"emoji":"📄","requires":{"bins":["python3"]}}}
---

# Papra document ingest

Files one or more local documents into **Papra** (the document archive on rpi5).
The file is copied into Papra's ingestion staging dir; a background feeder relays
it into Papra, which ingests it and the on-prem tag sweeper tags it within a few
minutes. Papra dedups by content hash, so re-filing the same file is harmless.

## Default invocation

```
python3 {baseDir}/scripts/papra_ingest.py <path-to-file> [<path-to-file> ...]
```

## Notes

- Accepts anything Papra ingests (PDF, PNG/JPG, etc.).
- Tagging is **on-prem only** (beast GPU); nothing goes to a cloud model. If beast
  is asleep/offline the document still files and is tagged on the next sweep.
- Prints the queued filename(s); the document shows up in Papra shortly after
  (ingestion polls every ~2 s, the inbox feeder every ~2 min).
- It does not upload over the network — it drops into a local staging dir that
  only this host's feeder reads.
