# Gateway webhooks, and pushing files into the EAI (interop-engine)

Triggers: expose an internal route publicly · `/external/webhook/<name>---<token>/…` · add a
`TRUSK_GATEWAY_WEBHOOK_*_TOKEN` · upload a file through the gateway and the service sees no file ·
`interop-engine-execution` / `interop-engine-check` · `POST /jobs/execution/:flowId` answers 201 but
no order · `check` says OK on a wrong flow · which EAI flow created an order.

## Two systems on gateway master (1.18.x)

- `/external/gateway/<api>/…` needs an **Auth0 JWT** whose audience matches the route
  (`src/gateway/gateway.config.ts`). Adding one means an Auth0 API + M2M client per env.
- `/external/webhook/<name>---<token>/<rest>` uses a **secret in the URL**, no Auth0
  (`src/webhook/webhook.config.ts`). Each entry has its methods (enforced, TEC-115), a target URL with
  `:params` filled from `<rest>`, static permissions and an expiry. The separator is **three dashes**
  (`symbolBetweenSlugAndToken`), even though `docs/interfaces.md` says `--`. Limit: 20 req/min per slug,
  then a 30 s block.

interop-engine has **no ingress** and every controller is `@Public()` (TEC-301 is still a branch).
Never give it an ingress: the webhook is the only safe way in.

## Adding a webhook without breaking an env

- Token in Infisical `/gateway-env-infisical`, per env. Previews have their own env importing staging
  (`infisical-cli.md`). The prod pod reads **only** `infra-env-infisical` + `gateway-env-infisical`,
  not the `infra-env` configmap: check the URL var exists **in the pod**, not in the configmap.
- A token env var declared plain `@IsWebhookToken()` is **required**: an env without it crashes on
  boot. For a new route, `@IsOptional()` + register the entries only when the token is set
  (`interopEngineWebhooks()` in 1.18.0). The image then ships anywhere before the secrets exist.
- The forwarder used to send `request.body`, which is **empty for multipart** (Nest parses only JSON
  and urlencoded). Since 1.18.0 it pipes the raw request with its original `content-length`. Never
  `JSON.stringify` the request in logs: it is circular.
- Forwarder timeout `HTTP_TIMEOUT` defaults to **6 s**: synchronous heavy targets can 502.
- A target URL with its own query string would let a caller inject `&filter…` through a path param,
  plus the caller's own query is forwarded. Encode query-placed params and drop the caller query
  (a design tried and reverted on 2026-09-30, not on master).

Live routes (1.18.0): `interop-engine-execution` / `interop-engine-check` → `POST
/jobs/{execution,check}/:flowId`, multipart `file`, token `TRUSK_GATEWAY_WEBHOOK_INTEROP_ENGINE_TOKEN`
(staging, prod, preview `pr-migration-ikea`). Reading an order: `quivr-getorder` → `GET
centiro-orders-api/order/:id`.

## interop-engine behaviours that surprise callers

- `POST /jobs/execution/:flowId` is synchronous and answers **201 even when the pipeline failed**:
  read `error` and each artifact's `errorMessage` / `responseId`, never the status code.
- `POST /jobs/check/:flowId` returns `totalFailed: 0` **for a flow id that does not exist** (checked in
  prod with `STMU-NOFLOW`, no job row written). A green check does not validate the flow.
- The flow, not the file, sets the contract, client and often the shipment site (mapping
  expressions like `{contract:<id>}`, `{shipment-site:<id>}`): those csv2 columns can be ignored.
- Which flow created an order: `GET /artifacts/children?filter.responseId=$eq:<orderId>` →
  `data[0].job.flow.id` (the OUTPUT_DELIVERY artifact). Only for orders created by the engine.
- Output delivery 503 = the target (COA) failed. Seen: COA got `ECONNREFUSED` on interop-configuration,
  which runs as 1 replica on a preemptible node and was being rescheduled. Retry is safe
  (`/order/upsert` keys on `shipment_number`).

csv2 (`csvTrusk2`) is read by **position**: 30 order columns, then groups of 6 per article
(`shipment-reader/…/csvTrusk2/schema.js`; EAI template « CSV 2.0 - Création de commande »).
