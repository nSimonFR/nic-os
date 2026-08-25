# Legacy trusk-api — users and PF Pro order visibility

Triggers: legacy user cannot see an order set · `trusk_customer` · `profile.truskCustomer` · `contract_ids` / `shipment_site_ids`

## Legacy users (trusk-api) — PF Pro order visibility

Users/organisations live in PG (`trusk_api`, schema `trusk`). Nicolas' staging user id is literally `nicos`.

PF Pro visibility = `trusk.users.trusk_customer` (read as `profile.truskCustomer`), matched against the mission's `customer_id`. To show a user a given order set, set it to that set's `mission.customer_id` — **mono-valued, it REPLACES the previous one**, and needs a re-login. Backoffice scoping is elsewhere: IAM's `contract_ids`/`shipment_site_ids`.

```sql
-- 1. target customer of the order set (order-mission DB)
SELECT DISTINCT m.customer_id FROM journey_trusk_order.order_mission om
  JOIN journey_trusk_order.mission m ON m.id = om.trusk_order_id
 WHERE om.log_order = ANY('{oKyRwdU20,Vhm82mz4j}') AND om.active;
-- 2. note the old value, then swap (trusk_api DB) — psql absent from the image,
--    run via the in-image `pg` driver: kubectl exec <trusk-api pod> -c trusk-api -- node -e '...'
SELECT id, email, trusk_customer FROM trusk.users WHERE id = 'nicos';
UPDATE trusk.users SET trusk_customer = '<customer_id>', updated_at = now() WHERE id = 'nicos';
```
