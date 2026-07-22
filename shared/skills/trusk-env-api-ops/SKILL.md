---
name: trusk-env-api-ops
description: Drive Trusk service APIs directly in a running environment (preview / staging / preprod) — authenticate, hit per-service endpoints (legacy trusk-api, centiro-orders-api/COA, order-mission, IAM), configure a user's data scope so they can SEE missions/orders (legacy truskCustomer + IAM client_id), inject an appointment to spawn a mission, reach in-ingress-less backends in-cluster, and run DB queries. Use when asked to configure a user, make a mission visible, call a Trusk API by hand, or set up test state in an env.
---

# Trusk env API operations

## Environment URL scheme
`<env>-{api,bo,backoffice,pro,track,rabbitmq}.trusk.com` (preview: `<env> = pr-<name>`):
- `-api` → **legacy trusk-api** · `-bo` → new backoffice · `-backoffice` → **legacy** trusk-backoffice · `-pro` → Plateforme Pro (`trusk-business`) · `-track` → tracking page.
- Backend services (COA, order-mission, IAM, roundtrip…) have **no public ingress** — reach them in-cluster (below).

## Auth
- **Legacy trusk-api**: `Authorization: Bearer <JWT>`. Use an infra/admin token — grab it from a logged-in BO session (browser devtools → Network → any request's `authorization` header) or an infra token. **Never commit a token to the repo** — obtain per use; they're env-scoped and expire.
- **COA (`centiro-orders-api`)**: controller is `@Public()` — no app auth (service-to-service). In-cluster only.
- **order-mission / IAM**: internal services, in-cluster only.

## Reaching in-ingress-less backends (in-cluster)
Prefer `node http` from any pod to the service DNS (port-forward is flaky):
```bash
CTX=trusk-staging-ts NS=pr-<name>
POD=$(kubectl --context $CTX -n $NS get po | awk '/^order-mission-.*Running/{print $1;exit}')
kubectl --context $CTX -n $NS exec $POD -c order-mission -- node -e '
const http=require("http");const d=JSON.stringify({date_range_from:"2026-07-24T06:00:00.000Z",date_range_to:"2026-07-24T16:00:00.000Z"});
const r=http.request({host:"centiro-orders-api",port:80,path:"/order/<id>",method:"PUT",headers:{"Content-Type":"application/json","Content-Length":Buffer.byteLength(d)}},x=>{let b="";x.on("data",c=>b+=c);x.on("end",()=>console.log("HTTP",x.statusCode))});r.write(d);r.end();'
```
DB queries via the in-image `pg` driver (no psql in the alpine images):
```bash
kubectl --context $CTX -n $NS exec $POD -c order-mission -- node -e '
const {Client}=require("pg");const c=new Client({host:process.env.POSTGRES_URL,user:process.env.POSTGRES_USER,password:process.env.POSTGRES_PASSWORD,database:process.env.POSTGRES_DB});
(async()=>{await c.connect();const r=await c.query("select ...");console.log(r.rows);await c.end();})();'
```
Service DBs (preview DB = `trusk_preview`): COA `ikea_orders.log_order` · order-mission `journey_trusk_order.order_mission` + `.mission` (has `customer_id`) · IAM `identity_access_management.users`.

## COA — order / appointment endpoints
- `PUT /order/:id/appointment/validated` (or `/admin/validated`) `{date_range_from,date_range_to}` — **validates against the calendar** → `appointment_unavailable` **412 on a fresh preview** (no delivery-zone calendar).
- `PUT /order/:id/appointment/postpone` `{source_name,source_type}` — nulls dates + `flow.appointment:false` + publishes `ORDER CANCELLED` (with source). *(the tracking "cancel" button calls this)*
- `DELETE /order/:id/appointment` `{source_name?,source_type?}` — cancel appointment (publishes `CANCELLED` with source).
- `PUT /order/:id` `{date_range_from,date_range_to,…}` — plain update, **no calendar check**; publishes `updated_log_order` on `trusk_log` → order-mission upserts.

### Spawn a mission on a fresh env (calendar-free)
`appointment/admin/validated` needs a calendar. Instead: take a `log_order` (from EDI/gen-data or `POST /order`) and **`PUT /order/:id` with `date_range_from/to`** → order-mission builds the OM + mission. (`source_type` enum values are spaced: `"Internal User"` / `"External User"` / `"Infra Trusk"`.)

## order-mission — list missions
`GET /missions?filter.customer_id=$eq:<customerId>&limit=20` (nestjs-paginate). Each mission carries `customer_id`.

## Configure a user so they SEE the missions (scope by customer)
Missions are scoped by **customer**, resolved from the logged-in user. Two separate systems / id-spaces:

**Legacy trusk-api** (drives the legacy `-backoffice` + the BFF the BO uses):
- The customer filter = the user's **`truskCustomer`** (`trusk-api bridges/bff.js`: `customerId = auth.truskCustomer` → `/missions` `filter.customer_id`).
- Read: `GET /user/:id` (Bearer) → `{truskCustomer, organisation, isAdmin, …}`.
- Set: **`POST /user/:id`** (⚠️ **POST, not PUT** — PUT returns 405) `{"truskCustomer":"<customerId>"}` (admin may set `truskCustomer`/`organisation`/`isDispatcher`).

**IAM (`identity-access-management`)** (drives the new `-pro` / new BO):
- User data scope = **`client_id`** (the company) + **`contract_ids`** + **`shipment_site_ids`** on `identity_access_management.users` (match by `email`). `client_id` = the customer id.
- Set via DB update (or the IAM user API) on the preview row.

Use the mission's **`customer_id`** for both `truskCustomer` and IAM `client_id` (same value worked in practice), and the order's `flow.contract_id` for IAM `contract_ids`. Legacy `organisation`, IAM `client_id`, and interop `contract` are **different id spaces** — don't mix them.

**After any scope change the user must re-login** — Auth0/session caches the old scope.

## Calendar config — unblock `/api/appointments` + the tracking postpone/cancel button
On the tracking page the schedule / **"Annuler ma livraison"** (postpone) UI renders only when `DisplaySchedule` sees **both** `enableScheduleModule` (order-level: the flag + an `appointment_selected` status) **and** `appointmentsData` (`/api/appointments/:id` → `calendar.getFreeAppointments`). A fresh preview has no calendar for the order's delivery zone → `/api/appointments` returns **412 `config_missing` / `calendar_not_defined`** → `appointmentsData` falsy → **button hidden**. (Same gap blocks appointment validation and roundtrip availabilities.)

`trusk-calendar` is **internal DB-backed** (schema `trusk`, no Google): 
- `trusk.appointment_availabilities` (`delivery_zone, brand, tag, date_search_from, date_search_to, date_search_split`) = the **calendar + search config** in one row. Lookup is `(zone, brand)` then falls back to `(zone)` — the zone-level row uses `brand='#NONE#'`, `tag='deliveryZone==<zone>'` (brand rows use `tag='deliveryZone--brand==<zone>--<brand>'`).
- `trusk.availabilities` = the actual bookable **slot events** per `tag` (only needed for a working appointment *picker*; the postpone/report path shows without slots).

**Unblock a zone (e.g. `idf_paris_pc`)** — insert one config row with a **current** window (in-cluster, calendar pod):
```bash
CTX=trusk-staging-ts NS=pr-<name>
CALP=$(kubectl --context $CTX -n $NS get po | awk '/trusk-calendar.*Running/{print $1;exit}')
kubectl --context $CTX -n $NS exec $CALP -c trusk-calendar -- node -e '
const {Client}=require("pg");const c=new Client({host:process.env.POSTGRES_URL,user:process.env.POSTGRES_USER,password:process.env.POSTGRES_PASSWORD,database:process.env.POSTGRES_DB,connectionTimeoutMillis:8000});
(async()=>{await c.connect();
await c.query("insert into trusk.appointment_availabilities (delivery_zone,brand,tag,date_search_from,date_search_to,date_search_split,created_at,updated_at) values ($1,$2,$3,$4,$5,$6,now(),now())",
  ["idf_paris_pc","#NONE#","deliveryZone==idf_paris_pc","2026-07-21T00:00:00.000Z","2026-08-12T00:00:00.000Z","2026-08-01T00:00:00.000Z"]);
await c.end();console.log("seeded");})().catch(e=>console.log("ERR",e.message));'
```
Pitfalls: pass **explicit ISO timestamps** (a `now() - interval '1 day'` built with escaped quotes silently inserted NULL dates); the calendar pod's PG connect can hang — wrap with `timeout 60` and set `connectionTimeoutMillis`. Verify: `/api/appointments/<orderId>` (via the tracking svc in-cluster) → **200** with `dateSearchFrom/To` + `appointmentsByDate`. Copy real window/slot shapes from **staging** (`kubectl -n staging exec <trusk-calendar> …` → `trusk.appointment_availabilities where delivery_zone='<zone>'`) if you need bookable slots too.

The order's `delivery_zone` is on the COA order (`flow.delivery_zone`) / `ikea_orders.log_order.flow_delivery_zone`.

## Gotchas
- trusk-api user update is **POST /user/:id** (PUT → 405).
- COA admin appointment-validate → **412** on fresh previews (no calendar); use `PUT /order/:id` with dates.
- Scope changes need a **re-login** to take effect.
- Preview DBs are isolated (`trusk_preview`) → mutations are safe/reversible; prod is a separate DB.
- **Never hardcode Bearer tokens** in the repo — fetch per session.

Related skills: `trusk-preview-deploy` (stand up the env), `trusk-preview-inject-data` (seed orders/missions via Argo workflows).
