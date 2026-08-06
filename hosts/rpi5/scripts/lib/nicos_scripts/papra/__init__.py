"""Papra document-management integrations.

Three units, all previously unimportable off-host — `papra-tag-sweep` opened a
SQLite connection at module level, `papra-webhook-tagsync` and
`papra-proton-poll` read `os.environ[...]` at module level and raised KeyError on
import. Nothing here runs at import time any more.
"""
