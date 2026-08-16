"""Immich reconcilers that Immich's own workflow engine cannot express.

Workflows only trigger on `AssetCreate` / `AssetMetadataExtraction`. There is no
"asset was added to an album" trigger, so anything keyed on album membership has
to be a timer that reconciles after the fact.
"""
