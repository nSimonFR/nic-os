"""The homepage-dashboard stats aggregator.

Every path it reads used to be a module-level constant — thirteen database paths
with no env override, which is why a 745-line file ran on exactly one machine.
They are all in `Config` now.
"""
