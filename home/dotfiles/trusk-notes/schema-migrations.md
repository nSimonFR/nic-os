# Schema migrations

Split out of `../CLAUDE.md`, which loads into every Trusk session — this does not.

## Migration footgun — never add steps to an already-applied migration

TypeORM/knex track migrations by name+timestamp. If a migration already ran (its row is in `_migrations`) and you later **add steps to that same file**, every env that recorded it **skips the new steps** → silent schema drift. Real case (state-status, 2026-07): the `label→status_label` / `detail→status_detail` rename was folded into the already-run `1782` split-drop-code migration. Staging had run 1782 **pre-rename** (the manual "run the migration in staging" step during review) → the 1.33.x redeploy saw 1782 in `_migrations` and skipped it → columns stayed `label`/`detail` while the entity mapped `status_label`/`status_detail` → **every write threw `42703 column status_label does not exist`** (TypeORM's post-insert entity reload). CI didn't catch it (CI builds the schema fresh from the full current migration; only envs with the stale recorded row drift). **Fix = a NEW idempotent migration** (rename only `IF EXISTS old_col AND NOT EXISTS new_col`, via a `DO $$ … $$` block) — never re-edit the applied one. Prod is safe if it never ran the intermediate version (it runs the complete migration once); the idempotent follow-up protects both.
