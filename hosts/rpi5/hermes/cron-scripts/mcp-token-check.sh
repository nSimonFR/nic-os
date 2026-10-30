#!/usr/bin/env bash
# Silent unless an OAuth MCP login (T3 Code: 30 days, no refresh) is missing or about to lapse.
exec @bin@/hermes-mcp-token-check
