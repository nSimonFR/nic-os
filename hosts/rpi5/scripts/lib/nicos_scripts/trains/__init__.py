"""Train price watches for Hermes: live prices, history, alerts.

`sources` fetches (OUIGO JSON API, TGV INOUI via 12train.com), `watch` owns the
SQLite state and the alert rules, `mcp` exposes both to Hermes over stdio, and
`hermes-train-watch` is the no_agent cron body that prints the alerts.
"""

__all__ = ["mcp", "sources", "watch"]
