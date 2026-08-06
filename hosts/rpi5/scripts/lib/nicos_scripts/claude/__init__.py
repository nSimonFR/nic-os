"""Agent-surface helpers: the notification aggregator and the claude-rc boot resume.

Both were built out of module-level mutable state (`_pending`, `_lock`, `_first_ts`
in the aggregator) or module-level constants, so neither could be exercised
without starting the real service. The state now lives in an object.
"""
