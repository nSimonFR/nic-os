# Prod vs staging — prérequis d'infra qu'un bump n'emmène pas

Triggers: bump prod isolé d'un service Nest 11 · `CreateContainerConfigError` / `FailedMount` sur `/etc/trusk-auth` · rollout prod bloqué en `ContainerCreating` sans erreur applicative · sidecar flagd qui ne démarre pas · source `flagd/shared-flags` introuvable · « pourquoi ça marche en staging et pas en prod » · `flagd-<svc>-<env>` bloqué `OutOfSync` avec `health=Healthy` · `spec.flagSpec.flags.<flag>.variants: Required value` · une release qui **retire** un flag · bascule d'un service vers Infisical

## La règle

Staging est routinièrement **plusieurs releases devant** la prod. Un bump prod « juste pour un fix » embarque toutes les releases intermédiaires **et leurs prérequis d'infra**, qui ne voyagent PAS avec le `targetRevision` : ils vivent dans `trusk-applications/manifests/` ou dans le repo d'un autre service. Vérifier le delta de versions ne suffit pas — il faut vérifier les prérequis. `targetRevision` est une version unique : on ne cherry-pick pas un fix sans son historique.

Avant tout bump prod d'un service passé aux libs `@trusk-official/nestjs-*`, dérouler la checklist en bas.

## Prérequis 1 — le secret `trusk-auth` (TEC-262)

Le montage vient du **chart du service**, `deployment/charts/default.yaml`, donc il s'applique à **tous les envs d'un coup** dès la release qui l'introduit :

```yaml
pod:
  mounts:
    secrets:
      - name: trusk-auth
        secretName: trusk-auth
        mountPath: /etc/trusk-auth
```

Clé `TRUSK_AUTH_SECRET` → fichier `/etc/trusk-auth/TRUSK_AUTH_SECRET`, chemin par défaut de `@trusk-official/nestjs-authentication`, relu toutes les 10 s (montage fichier et pas variable d'env, exprès : une rotation s'applique sans redéploiement). Renommer la clé ou le mountPath casse la paire **silencieusement** — le guard cesse simplement de vérifier.

Le Secret est un SealedSecret déclaré dans `trusk-applications` : `manifests/<cluster>/<ns>/common-config/trusk-auth-secret-sealed.yaml`. **Une valeur par env, jamais partagée** (un backoffice de preview ne doit pas pouvoir signer un token accepté en prod). Appliqué par l'app ArgoCD `common-config`, **priority 0** — elle existe déjà dans staging ET production, donc rien à câbler : un seul fichier à déposer.

⚠ **Le volume est rendu SANS `optional: true`.** Secret absent ⇒ kubelet ne démarre pas le conteneur ⇒ nouveaux pods en `ContainerCreating` + events `FailedMount`. Le déploiement ne se termine alors **jamais**, sans coupure ni erreur applicative : panne invisible si on ne regarde pas les pods.

Ce qui retient les anciens pods en service, c'est la **stratégie du Deployment**, pas le PDB — un PodDisruptionBudget ne contraint que les évictions *volontaires* (drain, API eviction), pas la mise à l'échelle du ReplicaSet par le contrôleur pendant un rolling update. Vérifié le 2026-08-31 : order-mission est en `RollingUpdate` `maxSurge: 25% / maxUnavailable: 25%` sur 2 replicas en staging **et** en prod — 25 % de 2 arrondit **à 0** indisponible, donc l'ancien ReplicaSet n'est pas réduit avant qu'un nouveau pod soit `Ready`. Preuve à l'appui : staging n'a **aucun** PDB pour ce service et les anciens pods ont quand même servi tout du long du bump 1.57.1 ; le `pdb.enabled: true / minAvailable: 1` du chart prod n'y joue aucun rôle.

Donc **contrôler la stratégie avant de promettre l'absence de coupure** : un service en `Recreate`, ou avec un `maxUnavailable` autorisant la disparition de tous les replicas, prendrait une vraie coupure sur ce même secret manquant. Au 2026-08-31 le namespace `production` n'en compte aucun (69 Deployments, 69 en `RollingUpdate`), mais c'est la chose à vérifier, pas à supposer :

```bash
kubectl --context $CTX -n production get deploy <svc> -o jsonpath='{.spec.strategy}{"\n"}{.spec.replicas}{"\n"}'
```

État au 2026-08-31 : présent en staging/preprod/previews depuis ~4 j ; créé en production le 2026-08-31 (`trusk-applications@b8cfabcd`). order-mission était le premier service prod à le monter — **backoffice prod (1.379.0) ne le montait pas encore**, donc personne ne signait avec ce secret en prod : le guard vérifiait des tokens que rien ne signait. Sans danger, parce que le flag d'enforcement `<service>_backend_authz` est `defaultVariant: "off"` (le guard vérifie, attache le principal, loge `auth.enforcement.bypassed`, **ne refuse rien**) — mais la fonctionnalité est inerte tant que le signataire n'est pas passé.

## Prérequis 2 — la `FeatureFlag` `shared-flags`, qui appartient au repo backoffice

Un service dont `deployment/flagd/featureflagsource.yaml` liste **deux** sources :

```yaml
sources:
  - source: flagd/<service>-flags   # livrée par son propre companion
  - source: flagd/shared-flags      # livrée par le repo BACKOFFICE
```

`shared-flags` porte `derive_author` (IN-763, fleet-wide) et est déclarée dans **`backoffice/deployment/flagd/shared-featureflag.yaml`**, synchronisée par `flagd-backoffice-<env>`. Introduite par le commit backoffice `48515c41`, **première release `1.383.0`**.

Donc : tout service référençant `flagd/shared-flags` exige **backoffice ≥ 1.383.0 déjà déployé dans cet env**. Au 2026-08-31, staging était en 1.384.5 (⇒ `shared-flags` présente) et prod en 1.379.0 (⇒ **absente**). C'est la cause exacte du « ça marche en staging, pas en prod ».

La doc trusk-k8s prévient qu'un pod annoté sans sidecar fonctionnel **crashloop** (`flagd/docs/index.md`). Le comportement du sidecar quand la **seconde** source manque n'a pas été observé — aucun service prod ne référence de source absente, donc pas de précédent. À ne pas supposer bénin.

## Ce qui, en revanche, vient gratuitement

L'app ArgoCD flagd du service (`flagd-<service>-<env>`) est un **companion auto-émis** par le chart `trusk-argo-project` dès que `deployment/flagd/` existe dans le repo du service. **Rien à ajouter dans `applications/<env>.yaml`.** Vérifié le 2026-08-31 : `flagd-order-mission-staging` est apparue seule au bump 1.57.1, créant `order-mission-flags` et `order-mission-flags-source`.

## Checklist avant un bump prod

```bash
CTX=gke_trusk-production-kkypwi_europe-west1_trusk-production-gke   # cf. proxy-prod
SVC=<service>

# 1. Le service monte-t-il trusk-auth à la version cible ?
#    `--name-status` AVANT les révisions : après le `--`, git le prend pour un pathspec et sort
#    le patch complet au lieu de l'inventaire, sans rien signaler.
git -C ~/MyDocuments/TRUSK/$SVC diff --name-status <verprod>..<vercible> -- deployment/
git -C ~/MyDocuments/TRUSK/$SVC show <vercible>:deployment/charts/default.yaml | grep -A4 mounts

# 2. Le secret existe-t-il en prod ?
kubectl --context $CTX -n production get secret trusk-auth

# 3. Le service lit-il shared-flags, et est-elle là ?
git -C ~/MyDocuments/TRUSK/$SVC show <vercible>:deployment/flagd/featureflagsource.yaml
kubectl --context $CTX -n flagd get featureflag shared-flags
awk '/- name: backoffice$/{f=1} f&&/targetRevision/{print;exit}' \
  ~/MyDocuments/TRUSK/trusk-applications/applications/production.yaml   # doit être >= 1.383.0

# 4. Qu'est-ce qui monte avec ? (les releases intermédiaires, pas juste ton fix)
git -C ~/MyDocuments/TRUSK/$SVC log --oneline <verprod>..<vercible> | grep -v 'Chore(Version)'
```

Conclusion pratique : pour un service dont la prod est plusieurs releases en retard et qui a franchi TEC-262 / flagd entre-temps, **une MEP globale staging→prod est plus sûre qu'un bump isolé** — elle emmène backoffice avec, donc les prérequis se résolvent par GitOps au lieu de gestes hors-bande.

## Prérequis 3 — TEC-275 casse aussi les **suppressions** de flag, pas seulement les créations

Le changelog de `trusk-argo-project` ne décrit le bug que côté *création*. **Il se déclenche identiquement quand une release RETIRE un flag** — vérifié en prod le 2026-09-07 sur la MEP des 6 services, après avoir conclu à tort la veille que « aucun flag ajouté ⇒ TEC-275 ne mordra pas ». Cette checklist-là est insuffisante : il faut differ les flags **dans les deux sens**.

Mécanisme : git ne déclare plus la clé, l'apply est un merge donc la clé live survit, `RespectIgnoreDifferences=true` strippe `.state`/`.defaultVariant`, il reste `<flag>: {}` — et le CRD exige `variants`. **L'apply entier échoue**, donc *aucun* des flags du fichier n'est mis à jour.

```
FeatureFlag "backoffice-flags" is invalid: spec.flagSpec.flags.roundtrip_panel_v2.variants: Required value
FeatureFlag "shared-flags"     is invalid: spec.flagSpec.flags.derive_author.variants: Required value
FeatureFlag "iam-flags"        is invalid: spec.flagSpec.flags.iap_admin.variants: Required value (retried 5 times)
```

Signature à reconnaître : l'app reste **`health=Healthy`** (les CRD live sont valides en tant qu'objets) pendant que `sync=OutOfSync` et `operationState.phase=Failed`, en retry perpétuel. Aucun monitoring basé sur la santé ne le voit.

Déblocage — retirer la clé orpheline du live pour que git et le cluster s'alignent :

```bash
kubectl --context $CTX -n flagd patch featureflag <name> --type json \
  -p '[{"op":"remove","path":"/spec/flagSpec/flags/<flag>"}]'
```

Snapshoter avant (`get -o yaml`). Sans danger si plus aucune version déployée ne lit le flag — le vérifier d'abord, par version *réellement déployée* et pas sur `master` :

```bash
git -C ~/MyDocuments/TRUSK/<svc> grep -c "readBooleanFlag(<CONST>)" <version-prod> -- src
```

Un `flags: {}` vide est valide (staging tournait comme ça depuis des jours).

**Chercher partout** : le 2026-09-07 les mêmes clés orphelines bloquaient trois apps dans deux clusters et trois namespaces — `flagd` en prod (backoffice-flags, shared-flags, iam-flags) et `flagd-preview` en staging (`flagd-preview-store`). Balayage :

```bash
kubectl --context $CTX -n argocd get applications | grep '^flagd'
kubectl --context $CTX -n flagd get featureflag -o json | jq -r '.items[] | "\(.metadata.name): \(.spec.flagSpec.flags | keys | join(", "))"'
```

Le correctif de fond est le chart **0.18.0** (`managedFieldsManagers: [kubectl-patch]` au lieu du filtre par chemin) — PR trusk-chart-museum#136, toujours ouverte au 2026-09-07.

## Les flags levés depuis l'UI ArgoCD s'éteindront le jour du bump chart 0.18.0

Un flag flippé depuis l'UI (ou par tout client qui n'envoie pas de field manager) est enregistré sous le field manager **`unknown`**.

**Avec le chart 0.17.0 — celui déployé — c'est stable.** Le filtre est *par chemin* (`jqPathExpressions` sur `.spec.flagSpec.flags[].state` et `.defaultVariant`), donc `.defaultVariant` est ignoré **quel que soit son propriétaire**. Conséquence contre-intuitive à connaître : l'app se déclare **`Synced/Healthy`** alors que git dit `off` et le live `on`. Ne pas lire un `Synced` comme « git et le cluster sont d'accord » sur ces deux champs — ArgoCD ne les regarde simplement pas.

**Le chart 0.18.0 change ça.** Il remplace le filtre par chemin par `managedFieldsManagers: [kubectl-patch]` : seuls les champs possédés par `kubectl-patch` restent ignorés. Tout ce qui appartient à `unknown` redevient un écart réel, et **selfHeal le ramène à la valeur de git**. Donc au bump du chart, chaque flag levé depuis l'UI **s'éteint en silence** — sans alerte, sans déploiement, sans rien dans les logs.

Audit à faire **avant** ce bump — la liste des flags qui vont retomber :

```bash
for f in $(kubectl --context $CTX -n flagd get featureflag -o jsonpath='{.items[*].metadata.name}'); do
  kubectl --context $CTX -n flagd get featureflag "$f" --show-managed-fields -o json \
    | jq -r --arg n "$f" '
      .spec.flagSpec.flags as $live
      | .metadata.managedFields[] | select(.manager=="unknown")
      | .fieldsV1["f:spec"]["f:flagSpec"]["f:flags"] // {} | to_entries[]
      | select(.value["f:defaultVariant"])
      | "\($n) \(.key[2:]) live=\($live[.key[2:]].defaultVariant)"'
done
```

Puis, pour chaque ligne, comparer à git (`git -C <svc> show <ver>:deployment/flagd/featureflag.yaml`) : si les valeurs diffèrent, le flag va basculer. Le remède est de le **reposer en `kubectl patch`**, ce qui transfère la propriété du champ à `kubectl-patch` et le remet sous protection.

État au 2026-09-07 en production — trois fonctionnalités actives ne tiennent que par le filtre par chemin :

| CRD | flag | live | git | au bump 0.18.0 |
| --- | --- | --- | --- | --- |
| state-status-flags | `state_status_order_validation` | on | off | **s'éteint** (IN-708) |
| state-status-flags | `mission_auto_delay_detection` | on | off | **s'éteint** (IN-589) |
| state-status-flags | `state_status_put_state_only` | on | off | **s'éteint** (IN-602) |
| iam-flags | `iam_backend_authz` | off | off | sans effet |
