# trusk-apps-scripts — Google Apps Scripts (clasp)

Triggers: `trusk-apps-scripts` · clasp `invalid_grant` · create, deploy or share a Sheet-bound script
· `deploy:dev` / `deploy:prod` · Script Très Mega Utile · an Apps Script calling a Trusk API.

## Layout and deploys

npm workspaces, one per script. Each has `encrypted/{development,production}/{clasp,config,appsscript}.json`
(sops: dev key `02F6A872…`, prod key `F7038F1E…`). The shared webpack decrypts them at build time into
`.clasp.json` / `src/config.json` (tracked template, force-added: without it CI lint fails on
`import/no-unresolved`) / `dist/appsscript.json`. `.gitignore` matches `config.json`: `git add -f` the
encrypted ones.

- `npm run deploy:dev` — by hand, from the Mac.
- `deploy:prod` — run by CI on release (multi-semantic-release `PREPARE_CMD`), with the `CLASPRC_JSON`
  account, which has edit rights via `gas@trusk.com` (verified 2026-09-30: CI pushed to a sheet shared
  only with `gas@`). A new prod sheet must be shared with `gas@trusk.com` as writer, or the release
  fails. Check the release log for `Pushed 2 files` + `Created version N`. To prove what is live,
  `clasp pull` the scriptId into a scratch dir.
- A new workspace releases 1.0.0 on its first `Feature` commit, so its prod `clasp.json` must be real
  before merge.
- `gas-webpack-plugin` emits a top-level stub for **every** `global.x =`, even inside `if`: guard
  prod-only restrictions inside the function, not around the export.

## clasp / Google auth from the agent

- `clasp login` needs a browser: ask for `! npx clasp login` once. `~/.clasprc.json` then holds a
  refresh token.
- `clasp create --type sheets --title … --rootDir .` (in a scratch dir) creates the Sheet + bound
  script owned by the logged-in user.
- The clasp token has `drive.file`: it can share / rename **files clasp created** through the Drive API
  (`permissions.create`, `sendNotificationEmail=false`). The Drive MCP cannot ("caller does not have
  permission"). Access token expired → refresh with `oauth2ClientSettings` + `token.refresh_token`
  against `https://oauth2.googleapis.com/token`. The Sheets API is disabled on clasp's GCP project:
  export as xlsx through Drive to inspect a sheet.
- Groups: `team@trusk.com` (everyone), `dev@trusk.com` (group « Dev »), `produit@trusk.com` is a
  **user** (« Team Produit »), `product@trusk.com` a group.

## Script Très Mega Utile (CO-153)

Workspace `script-tres-mega-utile`. csv2 order entry → EAI through the gateway webhooks
(`gateway-webhooks-eai.md`); import of an existing order through `quivr-getorder`.
DEV sheet `1C0Qw_b8TEA04W4lPK9dP-geusfRuJduVSJ0iln9zLdI` (dev@ + produit@), prod sheet
`1oxPIaL5uilO3Vjvqi4XfFfKs_GHbqB5VJqH6hGYAk2c` (team@). Tokens per env in `interopTokens` /
`quivrTokens` of the sops config; the dev env switch is shared by all users (Script Properties).
