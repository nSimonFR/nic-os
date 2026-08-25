# state-status and the consumer state mirrors

Triggers: `state_label` / `state_detail` wrong or stale · wiring a new `state.<ENTITY>.*` consumer · mirror drift · `StatusFindByEntityid`

## state-status ↔ consumer state mirrors (2026-07)

Each consumer keeps a local `state_label`/`state_detail` mirror, synced by consuming `state.<ENTITY>.*` off exchange `state-status` (`OrderStateSyncService` centiro, `Mission`/`OrderMissionStateSyncService` order-mission, `RoundtripStateSyncService` roundtrip). Prod mirror tables (DB `trusk`, id = state-status `entity_id`): `ikea_orders.log_order` (ORDER), `journey_trusk_order.order_mission` (ORDERMISSION) / `.mission` (MISSION), `roundtrip.roundtrip` (ROUNDTRIP).

- **Sync-back re-reads, never trusts the event payload.** Consumer must call `StatusFindByEntityid(entity,id)` (HTTP `GET /status/{entity}/{entityId}`, states `date DESC`; `.find(isState)`=latest) — writing `payload.statusLabel/statusDetail` verbatim clobbers under out-of-order delivery. Client base-URL defaults from `TRUSK_STATE_STATUS_API_URL || STATE_STATUS_API_URL`.
- **AND wrap a per-entity lock** (`lockService.lockBuilder(`<ent>:${id}`,…)`); fetch-latest alone still races. ORDERMISSION shipped without it → drift (fixed 1.46.2).
- **state-status publish**: `createStateForEntity` always publishes `StatusEvent` (no guard), routing `${isState?'state':'status'}.${entity}.${entityId}`; save-then-publish, no wrapping tx (committed before publish).
- **Cross-schema reconcile**: state-status DB role READs every schema but WRITEs only its own → joined UPDATE from the state-status pod fails `permission denied`; write each mirror from its **owning service's pod** (in-image `pg` driver).
- **Residual drift under burst**: even with lock+fetch, a small % of roundtrip mirrors drift during peak routing (load race); self-heals on next event, settled ones need a reconcile sweep (mirror ← state-status latest, bounded to the buggy window, SETTLED-only >5min).
