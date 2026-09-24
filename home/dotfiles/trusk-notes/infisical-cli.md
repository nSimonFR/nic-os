# Infisical CLI — `inf-stg` / `inf-prod`

Infisical is where Trusk services' secrets and env vars live (staging and prod instances);
these wrappers are how to read, set or inject them from the Mac.

Triggers: `infisical: command not found` · CLI prints an **empty table** with no error ·
`302` to `staging-auth` / `prod-auth.trusk.com` · `inf: … expired` · `403 Forbidden` from
`/api/v4/secrets` · read or set a staging/prod secret from the Mac · `infisical run` on a local
service · « which projectId / env ? » · agent shell says `INFISICAL_BIN: not set`.

## Use the wrappers — bare `infisical` is gone on purpose

`inf-stg` / `inf-prod` (`home/dotfiles/zsh/trusk.zsh`) take **exactly** the `infisical` argv.
The CLI is off PATH (`~/.local/libexec/infisical`, from nixpkgs-unstable via
`hosts/nbookpro/home.nix`) and there is no `infisical login` state (`~/.infisical` wiped with
`infisical reset` on 2026-09-24). Don't reinstall it from brew or log in again.

| | API URL | `--projectId` | `--env` |
| --- | --- | --- | --- |
| `inf-stg` | `http://infisical-infisical.infisical.svc.cluster.local:8080` | `9187f3c9-c6ba-4183-bf66-85fa59bbdd4d` (staging-cluster) | `staging`, `preprod`, `pr-*` |
| `inf-prod` | `https://infisical-prod.tail271d7a.ts.net` | `9037cafe-49b9-4d4c-9f84-60350dd10c52` (production-cluster) | `prod` |

Secrets live in **per-service folders** (`/backoffice-env-infisical`, `/infra-env-infisical`…);
the root is empty, so always pass `--path`. `secrets folders get` lists them.

```zsh
inf-prod secrets --projectId $P --env prod --path /infra-env-infisical
inf-stg  secrets set KEY=@/tmp/value --projectId $S --env staging --path /backoffice-env-infisical
inf-stg  run --projectId $S --env staging --path /backoffice-env-infisical -- npm run dev
```

**Set values from a file** (`KEY=@file`, `--file vars.env`), not inline: argv lands in atuin
history, which syncs to rpi5, and atuin only filters known token shapes.

## Why the public URLs don't work

`staging-infisical.trusk.com` / `infisical.trusk.com` are the UIs behind oauth2-proxy. The API
there answers `302` to `*-auth.trusk.com/oauth2/start` **even with a valid bearer** — the CLI
follows it, parses HTML and prints an empty table, exit 0. The APIs are tailnet-only
(`trusk-k8s/main/production/infisical/tailscale-ingress.yaml`, DO-1998). Staging's
`svc.cluster.local` name resolves via `/etc/resolver/cluster.local` → work CoreDNS over
tun2proxy, so it needs the work tailnet up.

## Tokens — user JWTs, 10-day TTL

One `infisical login` can't hold both instances: the keychain entry (`infisical-cli`) is keyed
by **email alone**, so logging into one evicts the other. Hence per-instance tokens in agenix
(`shared/secrets.zsh.age`): `INFISICAL_STG_TRUSK`, `INFISICAL_PROD_TRUSK`. They are Google-login
user JWTs; the wrapper decodes `exp` and fails with `inf: $VAR expired <date>` instead of a 401.

Refresh: new token from each instance, then re-encrypt to **both** recipients in
`shared/secrets.nix` (`age -r age1… -r "ssh-ed25519 …"`) — `age-edit` only uses
`~/.ssh/age.pub` and silently drops the ed25519 one — then `home-manager switch`.

Token and domain go in as `INFISICAL_TOKEN` / `INFISICAL_DOMAIN` env, **not** flags: flags
appended after `"$@"` would land on the child of `inf-stg run -- cmd`.

## Why a fixed path and not `$INFISICAL_BIN`

Home-manager session vars (`home.sessionVariables` and `programs.zsh.sessionVariables`) are
behind once-per-tree guards (`__HM_SESS_VARS_SOURCED`, `__HM_ZSH_SESS_VARS_SOURCED`). Any shell
inheriting the guard — herdr panes, agent shells started before the switch — never sees a new
var. The `~/.local/libexec` symlink works in every shell.
