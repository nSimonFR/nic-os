# Data & analytics MCPs — Steampipe and Metabase

Triggers: GCP inventory as SQL · warehouse / analytics query · Steampipe · Metabase · `execute_query` · `create_question` · pMBQL · `The token request is invalid` · clear authentication · `This tool is not available` · `conflict with recovery` · `prod-warehouse` · dbhub · cross-schema join

## Steampipe — GCP-as-SQL (`trusk-steampipe` MCP)

`trusk-steampipe` = query **GCP as live SQL**. Only the `turbot/gcp` plugin is installed, so it's for Google Cloud inventory/IAM/audit introspection — `SELECT … FROM gcp_compute_instance / gcp_kubernetes_cluster / gcp_service_account …`, read-only, hits the real GCP API per query (nothing cached). Use it instead of `gcloud … | jq` for cross-resource GCP questions. It's **not** fronted by the ToolHive proxy (no GCP there; `dbhub` is real-database-only) — kept as its own MCP.

## Metabase — query via the `metabase` MCP (not the old cookie skill)

Analytics SQL on the data-warehouse goes through the **`metabase` MCP** (`mcp__metabase__*`, OAuth — first call → `authenticate` returns a browser URL to approve). Replaced the retired cookie `metabase` skill; wired in nic-os `home/mcp.nix` + allowlisted in `claude-settings.json`.

- Endpoint is **`/api/mcp`** (docs' `/api/metabase-mcp` 404s on v0.61.2.10). Warehouse = **database id 6**.
- Flow: `search` → `get_table {with-fields:true}` → `construct_query`/`query` → `execute_query` → `create_question`. `execute_query` caps at **200 rows** (saved cards show all). `create_question` `collection_id:null` → root "Our analytics" (no collection-lookup tool; move in UI). Link: `metabase.trusk.com/question/<id>`.
- **Joins are unbuildable via `construct_query`** (`String cannot be cast to Associative`). Workaround — save any SQL (incl. joins) as a question by hand-crafting the base64 `query` as a native pMBQL stage, then pass to `execute_query`/`create_question`:
  ```bash
  jq -nc --arg q "$SQL" '{"lib/type":"mbql/query","database":6,"stages":[{"lib/type":"mbql.stage/native","native":$q}]}' | base64 | tr -d '\n'
  ```
- **`Failed to reconnect to metabase: The token request is invalid`** → `/mcp` → **clear authentication**, then reconnect. "Reconnect" alone replays the stale DCR client and reproduces the error indefinitely. Clearing forces a fresh registration; works first try.
- **claude.ai connector "Metabase Trusk" is read-only in practice.** `execute_query` / `get_table` reach Metabase; `create_question` returns `permission_error: This tool is not available` with an Anthropic `req_…` id and **without schema validation** (omitting required params changes nothing) — the call never leaves Claude, so it is *not* an OAuth scope problem. Use the local `metabase` MCP to write.
- **API keys don't work on `/api/mcp`.** `X-Api-Key` → same 401 as no auth at all; only OAuth bearer is accepted (a bogus bearer gives a distinct `invalid_token`). No key-based shortcut.
- **Verify `database id 6`** by reading `metabase.report_card` on `prod-warehouse`: the `metabase` schema there replicates part of Metabase's own app DB (`report_card`, `collection`, `core_user`, `query_execution`, `report_dashboard`). Cards per `database_id` answer "which connection do the real questions use".

## Warehouse (`prod-warehouse` via dbhub · Metabase db 6)

- DB `warehouse`, user `mcp_readonly`. **Replicates the OLTP schemas**, incl. `ikea_orders` (COA) and `journey_trusk_order` (order-mission) → **cross-service joins in one native question**.
- **~5h lag** — periodic snapshot, not live (2026-08-26: latest rows 09:01 for a warehouse clock of 14:17). Any column derived from live state (mission status, order state) is stale by that much; recheck on the OLTP before acting on a per-row list.
- **`canceling statement due to conflict with recovery`** = hot-standby killing a long query. Narrow the window (180d → 45d sufficed). A saved card run from the UI is unaffected.
