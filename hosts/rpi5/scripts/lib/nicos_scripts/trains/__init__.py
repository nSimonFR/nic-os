"""Live train prices for Hermes.

`sources` fetches (OUIGO JSON API, TGV INOUI via 12train.com); `mcp` exposes them
to Hermes over stdio.
"""

__all__ = ["mcp", "sources"]
