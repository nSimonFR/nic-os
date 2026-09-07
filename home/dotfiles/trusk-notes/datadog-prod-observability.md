# Datadog prod — ce que chaque service loggue vraiment, et le bruit à exclure

Triggers: « pas d'erreurs sur Datadog » comme preuve de santé · vérifier un déploiement prod dans les logs · pic d'erreurs juste après un rollout · `auth.enforcement.bypassed` en volume · monitor `[LOGS] — … burst` qui alerte · comparer un taux d'erreurs à une baseline · `service:backoffice` vs `service:trusk-backoffice` · `@version` absent d'un service

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

## Baselines — jamais une heure creuse contre une heure de pointe

Une baseline prise à 06:00 comparée à un déploiement de 10:00 donne un facteur 3 qui n'est qu'un profil de trafic. **Comparer la même tranche horaire d'un jour ouvré comparable** :

```
from: "3d@09:45:00"   to: "3d@10:00:00"
```

⚠ **`3d@HH:MM` est interprété en heure LOCALE**, pas en UTC — alors que les `meta.from`/`meta.to` de la réponse sont en Z. `3d@07:45` a renvoyé `2026-09-04T05:45:00Z`. Vérifier le `meta` de la réponse avant de conclure.

Mesuré ainsi : order-mission 5,5 erreurs/min vendredi 09:45–10:00 contre 8,5 pendant la bascule — écart entièrement expliqué par la redélivrance AMQP au redémarrage des pods, retombé ensuite.

## Motifs de bruit pré-existants, par service (2026-09-07)

À connaître pour ne pas les prendre pour des régressions :

- **order-mission** — `GET /missions/<id> 503`, `Failed to get availability: <id>`, `Error processing action for status`, `trusk_order_retrieve_error`, `[MissionStateSyncService] Mission not found`. Les **mêmes ids de mission** reviennent en boucle (retries) : si les ids d'après le déploiement sont ceux d'avant, ce n'est pas une régression.
- **centiro-orders-api** — `GET /order/<id> 404`, en warn, plusieurs milliers/h.
- **roundtrip** — `GET /roundtrips/order/<id> 404` + `Roundtrip not found for order_id`.
- **front-tracking-page** — `Failed to get trusker infos … order_error_notexist`, `Failed to fetch appointments: appointment_not_handled`.

## Next.js — le faux positif de déploiement à connaître

Après tout déploiement de backoffice, les navigateurs restés ouverts sur l'ancien build postent des Server Actions dont l'id n'existe plus :

```
Error: Failed to find Server Action "<hash>". This request might be from an older or newer deployment.
```

Ça déclenche le monitor DO-2005, ça se résorbe seul quand les gens rechargent, et **il n'y a rien à corriger**. Le 2026-09-07 : 18 erreurs, alerte à 11:37, récupération à 12:07 pour un déploiement de 10:15 — le décalage vient du temps qu'il faut aux utilisateurs pour recliquer, pas du boot. Aucun 5XX, `/api/health` à 200 tout du long.
