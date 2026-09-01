# Backoffice deep links, and the order ↔ mission id mapping

Triggers: need a BO URL for a specific order / mission / roundtrip · `primary=` `secondary=` `primaryTab=` query params · `staging-bo.trusk.com` · "which id does the BO use for a commande?" · `log_order` vs `trusk_order_id` · linking someone straight to a status tab · `GET /missions/<id>` returns 503 `Failed to fetch availability`

## Hosts

`deployment/charts/default.yaml` sets `bo.trusk.com`; `ingress.hostPrefix.useNamespace` prepends the namespace everywhere except production.

| env | host |
| --- | --- |
| production | `https://bo.trusk.com` (`useNamespace: false`) |
| staging | `https://staging-bo.trusk.com` |
| preview | `https://pr-<n>-bo.trusk.com` |

`staging-backoffice.trusk.com` is the **legacy** BO (`trusk-backoffice` ingress, 2y+ old) — not this app.

## URL shape

`routing.ts` sets `localePrefix: "never"` → **no `/fr` segment**, paths are bare (`/orders`, `/roundtrips`).

```
https://staging-bo.trusk.com/orders
  ?primary=<resourceType>~<id>&primaryTab=<tabId>
  &secondary=<resourceType>~<id>&secondaryTab=<tabId>
```

Parsed in `src/contexts/resourceContext.tsx:82-97` — the separator is a **tilde**, `primaryParam.split("~")`. Any page that mounts `ResourceProvider` + `DrawerPanel` honours these, so `/orders` opens a mission panel fine; you don't need a per-entity route (there isn't one — missions have no page of their own, only a panel).

Resource types (`src/contexts/types.tsx`, `RESOURCE_TYPES`): `truck` `trusker` `carrier-company` `contract-trusker` `contract-client` `contract-pricing-offer` `shipment-site` `roundtrip` `order` `mission` `flow` `output` `mapping` `end-client` `trusker-notifications` `job` `user` `availability-assignment` `delivery-zone`.

**Tab ids are per-panel and are not reliably the `TAB_TYPES` enum** — read the panel's own `getTabs()`:

| panel | tab ids |
| --- | --- |
| `components/panel/mission/index.tsx` | `mission` · `price` · `state-statuses` |
| `components/panel/orders/index.tsx` | `order` · `order-mission` · `price` · `status-legacy` · `state-status` |

Watch the near-miss: the mission's status tab is `state-statuses` (**plural**), the order's is `state-status` (**singular**). Wrong id = panel opens on its default tab, no error.

## BO order id ≠ mission id

- BO **commande** id == order-mission `log_order`
- BO **mission** id == order-mission `trusk_order_id`

Authority: `app/[locale]/orders/hooks/use-enriched-order.ts` feeds the orders list's `order.id` straight into `filter.log_order`.

Resolve one from the other through order-mission. **Trap: the query param is named `orderId` but takes the *mission* id**:

```bash
GET http://order-mission/order-mission?orderId=<missionId>    # by trusk_order_id
GET http://order-mission/order-mission?logOrder=<orderId>     # by log_order
# → { id, attributes: { log_order, trusk_order_id, type, active, state_label, … } }
```

Pass exactly one of `orderId` / `logOrder` — both or neither → 400 (`orderMission.controller.ts:33`). `orderId` implies `includeInactive`, so historized (redelivered/failed) mappings still resolve.

`GET /missions/<id>` carries `order_number` (the client's ref, e.g. `hypnia_5184`) but **no order id at all** — /order-mission is the only way across.

## `GET /missions/<id>` → 503 `Failed to fetch availability <id>`

Stale staging data: the mission row exists but references a deleted availability, and the enriched read can't serve it. The BO panel won't load either. Not a permissions or routing problem — pick another mission.

## Worked example (staging, 2026-09-01)

Mission `pW4AE1idDkr` → `order-mission?orderId=pW4AE1idDkr` → `log_order: scMm-gpXt`.

```
# commande primary, mission secondary on its statuses tab
https://staging-bo.trusk.com/orders?primary=order~scMm-gpXt&primaryTab=order-mission&secondary=mission~pW4AE1idDkr&secondaryTab=state-statuses

# mission alone
https://staging-bo.trusk.com/orders?primary=mission~pW4AE1idDkr&primaryTab=state-statuses
```
