# Datadog prod — ce que chaque service loggue vraiment, et le bruit à exclure

Triggers: « pas d'erreurs sur Datadog » comme preuve de santé · vérifier un déploiement prod dans les logs · pic d'erreurs juste après un rollout · `auth.enforcement.bypassed` en volume · monitor `[LOGS] — … burst` qui alerte · comparer un taux d'erreurs à une baseline · `service:backoffice` vs `service:trusk-backoffice` · `@version` absent d'un service · surveillance MEP toutes les 5 min · un service absent d'un `groupBy ["service"]` · `0d@HH:MM` UTC ou local ? · ce motif est-il nouveau ?

## La règle

**L'absence de logs n'est pas une preuve de santé.** Les services migrés Nest 11 lisent `LOGGER_LEVEL` (défaut `error`) : beaucoup ne loggent qu'en erreur, et rarement. Une fenêtre de 30 min sans rien ne distingue pas « sain » de « ne loggue pas ». Toujours croiser avec un signal *positif* : `rollout status`, `restartCount`, et une requête HTTP réelle.

Vérifié le 2026-09-07 pendant la MEP staging→prod de 6 services.

## Facettes — `kube_namespace`, pas `namespace`

`kube_namespace:production` **fonctionne** et attrape tout le namespace, y compris les services qu'on n'a pas pensé à lister. `namespace:production` et `env:production` ne sont pas des facettes.

La requête de balayage qui a servi à tout trouver :

```
kube_namespace:production -status:(debug OR info)
```

Filtrer par `service:(a OR b OR …)` fait manquer ce qu'on n'a pas anticipé — c'est comme ça qu'on est passé à côté des warns pendant deux heures.

## Le bruit à exclure SYSTÉMATIQUEMENT

Trois familles polluent tout comptage, et deux explosent **à chaque déploiement** :

| motif | pourquoi | effet si non exclu |
| --- | --- | --- |
| `auth.enforcement.bypassed` | une ligne **par requête**, émise tant que `<service>_backend_authz` est `off`. Le guard vérifie le token, attache le principal, loggue ce qu'il aurait refusé, ne refuse rien. Audit par design (IN-857). | domine tout : 20 643 warns/h sur fleet, 27 813 sur order-mission |
| `npm notice`, `npm error … debug-0.log` | stderr d'npm au démarrage, classé `status:error` | chaque nouveau pod produit une salve → faux pic post-déploiement (85 des 215 « erreurs » fleet) |
| `DeprecationWarning: Client.queryQueue…` | stderr du conteneur de migration (`<svc>-pgm`), classé `error` | idem, plus un `GET /health/readiness 503` sur l'ancien pod pendant son drain |

Requête de comptage utilisable :

```
kube_namespace:production -status:(debug OR info) -"npm notice" -"npm error" -"npm warn" -"auth.enforcement.bypassed"
```

## Noms de service — deux pièges

- **`backoffice` → `service:backoffice`.** Le service `trusk-backoffice` est l'app **LEGACY**. Chercher `service:*backoffice*` remonte d'abord le legacy et fait conclure n'importe quoi. Le vrai backoffice loggue peu (erreurs seulement) — sur une fenêtre calme on ne voit que son sidecar (`service:flagd`, `pod_name:backoffice-*`), ce qui **ne veut pas dire** qu'il n'envoie rien.
- Il existe un monitor dédié : **`[LOGS] — Backoffice error-log burst`** (id `303735315`, p2, DO-2005), `logs("service:backoffice status:error").last("30m") > 15`, baseline ~0,4/30 min.

## `@version` — présent pour certains services seulement

`groupBy ["@version"]` est **l'outil décisif** pour séparer « la version qu'on vient de livrer » de « ce qui existait déjà » : pendant un rolling update les deux versions loggent en parallèle, et un total cumulé fait croire à une régression.

| émettent `@version` | n'en émettent pas |
| --- | --- |
| state-status, fleet, order-mission, roundtrip, centiro-orders-api | identity-access-management, backoffice |

Pour les seconds, discriminer sur **`pod_name`** : le nouveau ReplicaSet a un hash différent (`iam-9f64f66d5-*` vs `iam-597845fbc4-*`).

Exemple réel : fleet avait 4 873 warns sur l'heure du déploiement — **4 854 sur 1.80.2 et 19 sur 1.82.1**. Sans le `groupBy`, on aurait attribué le bruit à la version qu'on venait de livrer alors qu'elle le supprimait.

### ⚠️ Le paramètre `keyword` est IGNORÉ en mode `aggregate`

`tech-datadog_logs` accepte `keyword` (grep de texte) et `query` (syntaxe Datadog). En `action: "aggregate"`, **`keyword` ne filtre rien** : les buckets renvoyés sont le volume de logs **total** par groupe, quel que soit le mot-clé.

Le contrôle qui le démontre — passer une chaîne qui ne peut rien matcher et constater des totaux identiques :

```
# faux : keyword ignoré, on lit le volume total par version
{action: aggregate, query: "service:order-mission kube_namespace:production",
 keyword: "trusk_order_retrieve_error", groupBy: ["@version"]}
→ 1.60.0: 767 006 · 1.62.0: 4 334 603 · 1.66.2: 2 749

{… keyword: "zzzz_ne_matche_rien_zzzz" …}   # contrôle
→ 1.60.0: 705 990 · 1.62.0: 4 334 603 · 1.66.2: 60 538   # mêmes ordres de grandeur

# correct : le texte entre guillemets DANS query
{action: aggregate, query: "service:order-mission kube_namespace:production \"trusk_order_retrieve_error\"",
 groupBy: ["@version"]}
→ 1.60.0: 3 897 · 1.62.0: 34 730 · 1.66.2: 334
```

Écart réel : **~4 000/jour**, annoncé à tort comme ~1,5 M/jour — facteur 300, et un ticket « bruit de logs à traiter » ouvert pour rien (2026-09-15, order-mission 1.66.2). La conclusion qualitative (« pré-existant, pas une régression ») tenait quand même, mais aucun des chiffres n'était le bon.

**Réflexe** : tout nombre issu d'un `aggregate` avec `keyword` doit être revérifié avec le motif dans `query`, et un contrôle à chaîne absurde coûte un appel.

En `action: "search"`, `keyword` fonctionne — c'est bien le couple `aggregate` + `keyword` qui est piégeux.

## Baselines — jamais une heure creuse contre une heure de pointe

Une baseline prise à 06:00 comparée à un déploiement de 10:00 donne un facteur 3 qui n'est qu'un profil de trafic. **Comparer la même tranche horaire d'un jour ouvré comparable** :

```
from: "3d@09:45:00"   to: "3d@10:00:00"
```

⚠ **`3d@HH:MM` est interprété en heure LOCALE**, pas en UTC — alors que les `meta.from`/`meta.to` de la réponse sont en Z. `3d@07:45` a renvoyé `2026-09-04T05:45:00Z`. Vérifier le `meta` de la réponse avant de conclure.

Mesuré ainsi : order-mission 5,5 erreurs/min vendredi 09:45–10:00 contre 8,5 pendant la bascule — écart entièrement expliqué par la redélivrance AMQP au redémarrage des pods, retombé ensuite.

⚠ Le 2026-09-29, `0d@07:00` a au contraire été lu en **UTC**. Les deux comportements ont été observés : ne se fier à aucun, passer des timestamps ISO explicites (`"2026-09-29T07:40:00Z"`) et relire `meta.from`.

**Une salve se compare à la pointe de la matinée, pas au même créneau de 5 min.** service-onfleet : 255 warns à 07:40Z contre 1 « la veille à 07:40 » — mais la veille la salve du dispatch matinal était tombée à 06:55–07:10 (256), et le mardi précédent à 06:10 (366). Pour un service à salves, comparer le **pic** de la même matinée sur 2-3 jours, et le total d'une fenêtre d'1 h.

## `groupBy ["service"]` plafonne à 10 buckets

Un `aggregate` groupé par service ne renvoie que **10 services**, sans rien signaler : les suivants disparaissent du résultat, et un service qui déraille peut ne jamais apparaître. Balayer en plusieurs requêtes de ≤ 10 services, plus une requête complément qui exclut toutes les listes :

```
… service:(api-pusher OR billing OR … )          # A, 10 services
… service:(fleet OR front-tracking-page OR … )    # B
… service:(service-onfleet OR trusk-api OR … )    # C
… -service:(<A> OR <B> OR <C>)                    # D : tout le reste — c'est là qu'apparaissent les surprises
```

La requête D a remonté les trusk-mail-*, trusk-cresus-*, trusk-auto-status, trusk-webhook-dispatcher : aucun n'était dans la liste de départ. En `search`, passer `compact: true` : sans, un échantillon « diverse » de centiro-orders-api a fait 1 Mo (listes d'ids dans le message).

## Motifs de bruit pré-existants, par service (2026-09-07)

À connaître pour ne pas les prendre pour des régressions :

- **order-mission** — `GET /missions/<id> 503`, `Failed to get availability: <id>`, `Error processing action for status`, `trusk_order_retrieve_error`, `[MissionStateSyncService] Mission not found`. Les **mêmes ids de mission** reviennent en boucle (retries) : si les ids d'après le déploiement sont ceux d'avant, ce n'est pas une régression.
- **centiro-orders-api** — `GET /order/<id> 404`, en warn, plusieurs milliers/h.
- **roundtrip** — `GET /roundtrips/order/<id> 404` + `Roundtrip not found for order_id`.
- **front-tracking-page** — `Failed to get trusker infos … order_error_notexist`, `Failed to fetch appointments: appointment_not_handled`.

Complété pendant la MEP du 2026-09-29 (44 services), chaque motif vérifié par `groupBy ["@version"]` sur 3-14 j — l'ancienne version l'émettait déjà :

| service | motif | ordre de grandeur (ancienne version) |
| --- | --- | --- |
| centiro-orders-api | `error: bind message has <N> parameter formats but 0 parameters` (IN géant), `GET /delivery-zone … 500` | ~590 erreurs/sem |
| trusk-templates-pickup | `Error checking is_communication_migrated … 404`, err + warn | ~100 k/j, ~1 100 / 5 min |
| trusk-calendar | `Validation schema error for headers/updated_order/trusk_api.updated_order`, par salves de 60+ | ~9 000/sem |
| service-onfleet | warn `resource_busy` (lib-lock, `(1/100)` puis `finally executed after 1 retries`) + `roundtrip.ordering_context_no_mission_type` : salve du dispatch matinal, jusqu'à ~350 / 5 min | ~23 k warns / 3 j |
| service-onfleet | erreur `trusker_location_hotspot_queue` par salves de ~25 | ~440/j |
| trusk-webhook-dispatcher | `[Logger] Warning! Only 2 first parameters are processed` — suit le trafic webhook, 200-1 400 / 5 min | ~4 000/h en matinée |
| trusk-auto-status | `Failed creating the status, discarding the job!` (404 order-mission) | ~1 200/j |
| interop-configuration | `GET /contract-pricing-zones/search-by-client?… 404` | ~15 / 5 min |
| trusk-estimator-api | `POST /estimates/order/<id> 404` | ~30-90 / 5 min |
| trusk-cresus-upsert-transaction-missions-sync | `No service provider found for siret`, par salves | ~2 500/sem |
| api-pusher | `Woop - Update status of delivery error : <id>` = Woop 403 `Delivery #<id> is outdated`, une livraison à la fois | ~64 / 14 j |
| trusk-api-warehouse | `[Quote] Error creating quote … 400` = géocodage Google refusé sur une adresse dont l'accent a été supprimé (`SURS` pour `SœURS`) | ~50 / 14 j |
| trusk-mail-*, trusk-mailer | `(node:1) NOTE: The AWS SDK for JavaScript (v2)…` (5 lignes `error`) et `SIGTERM` à chaque redémarrage de pod | 10 / pod |
| billing 1.4.0 | `No client/fleet billing account for mission <id>` ×4 par mission — attendu tant que `billing.billing_account` est vide en prod (lignes rattachées rétroactivement à la création du compte) | ∝ missions |

Deux faux signaux de la même matinée : **trusk-webhook-dispatcher** et **order-mission** à ~3× la semaine précédente, mais à volume égal entre pods ancienne/nouvelle version (2 366 vs 2 370) → c'est le trafic, pas la version. Et `trusk-backoffice` (legacy) remonte des `npm ERR!` : à ignorer comme tout le legacy.

## Next.js — le faux positif de déploiement à connaître

Après tout déploiement de backoffice, les navigateurs restés ouverts sur l'ancien build postent des Server Actions dont l'id n'existe plus :

```
Error: Failed to find Server Action "<hash>". This request might be from an older or newer deployment.
```

Ça déclenche le monitor DO-2005, ça se résorbe seul quand les gens rechargent, et **il n'y a rien à corriger**. Le 2026-09-07 : 18 erreurs, alerte à 11:37, récupération à 12:07 pour un déploiement de 10:15 — le décalage vient du temps qu'il faut aux utilisateurs pour recliquer, pas du boot. Aucun 5XX, `/api/health` à 200 tout du long.
