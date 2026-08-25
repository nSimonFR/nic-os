# Data & analytics MCPs — Steampipe and Metabase

Triggers: GCP inventory as SQL · warehouse / analytics query · Steampipe · Metabase · `execute_query` · pMBQL

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
