"""Papra document-management integrations.

`papra-tag-sweep` used to open SQLite at module level and `papra-proton-poll`
read `os.environ[...]` at module level, so neither imported off-host. Nothing
here runs at import time any more.
"""
