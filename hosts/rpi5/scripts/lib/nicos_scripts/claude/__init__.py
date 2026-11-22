"""Agent-surface helpers: the notification aggregator, the context baseline,
the 5h-window anchor and the T3 settle retro.

The aggregator was built out of module-level mutable state (`_pending`, `_lock`,
`_first_ts`), so it could not be exercised without starting the real service.
The state now lives in an object.
"""
