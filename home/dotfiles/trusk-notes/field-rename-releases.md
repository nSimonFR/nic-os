# Renommer / scinder un champ exposé par une API — procédure de MEP

Triggers: renommer une colonne ou un champ d'API lu par d'autres services · retirer une double écriture · étape *contract* d'un expand/contract · `filter.<ancien_nom>` · « on a bien tous les consommateurs ? » · `nestjs-paginate` ignore un filtre en silence · zéro résultat sans erreur après un déploiement · `throwOnInvalidFilter` · IN-731 / IN-864 / IN-1034

## La revue de code ne suffit jamais à établir la liste des consommateurs

**Surveiller les appels HTTP à l'ancien format dans Datadog est une exigence, pas une option.** Sur IN-864 (retrait de la double écriture `order_mission.trusk_order_id` → `mission_id`, MEP le 21/09/2026) la revue de code avait « validé » la liste des consommateurs. La méthode par les logs en a trouvé **deux de plus**, dont un qui aurait cassé en silence :

- `service-onfleet` (~2 250 appels/h) — corrigé en 2.59.1 ;
- l'ordo CCD Apps Script, invisible au grep **et** à la recherche de code GitHub.

Pourquoi le code ne suffit pas, concrètement :

- **33 des 56 services prod ne sont pas clonés** sur la machine → un `grep` sur `~/MyDocuments/TRUSK/*` couvre moins de la moitié de la surface.
- La recherche de code GitHub org-wide **n'est pas exhaustive** : `trusk-apps-scripts` n'est pas indexé (contrôle positif fait le 21/09 : 0 résultat sur une chaîne présente dans le repo). Toujours faire un contrôle positif avant de conclure « aucun appelant ».
- Les Apps Scripts, Metabase, les robots et tout ce qui n'est pas un repo de service échappent par construction au grep.
- Un checkout local sur une branche de correctif **masque** l'occurrence sur `master` — vérifier avec `git grep <motif> origin/master`, pas avec le working tree.

## Le mode de panne à redouter : `nestjs-paginate` ignore un filtre inconnu

`throwOnInvalidFilter` est **off** par défaut. Un filtre sur une colonne non whitelistée ne lève rien : order-mission répond **200 avec une page non filtrée** (ou vide). Pas de 400, pas de log, aucun signal Datadog. Le consommateur continue de tourner en rendant zéro résultat, ou se rattache à la première ligne venue.

C'est ce qui a produit IN-1034 : state-status 1.42.1 a déplacé ses trois lectures du lien mission sur `filter.mission_id`, ce qui ne résout rien pour une course de contrat non migré (`mission_id` NULL). Le miss était un `logger.debug` et la prod tourne en `LOGGER_LEVEL=error` → **deux jours de statuts gelés, 4 611 commandes**, détectés par personne. Corrigé en 1.43.2 par une lecture des deux colonnes (`mission_id` d'abord, `trusk_order_id` en repli).

**Corollaire pour les tests** : asserter la **clé de filtre émise** (`expect(search).toHaveBeenCalledWith({'filter.mission_id': [...]})`) et le **nombre d'appels**. Une mauvaise clé ne lève pas, donc seule une assertion sur la query la rattrape.

## Procédure

1. **Avant la MEP — inventorier les appelants par les logs, pas par le code.**

   ```
   # qui appelle l'ancien format, et à quel volume
   tech-datadog_logs aggregate
     service:<svc> kube_namespace:production "filter.<ancien_nom>"
     groupBy ["@request_headers.user-agent"]        # discriminant le plus fiable
     groupBy ["@request_headers.x-origin-service"]  # seulement si l'appelant est sur trusk-app >= 0.15
   ```

   Puis un `search` **non compact** sur un échantillon : `request_headers` donne `user-agent`,
   `x-origin-service` et l'`authorization` (le JWT `iss`/`sub` nomme le service), et `body.meta.totalItems`
   dit si la réponse est déjà vide.

2. **Identifier chaque appelant avant de partir.** Un appelant non identifié est un no-go. Pièges vus :
   - **un proxy masque l'appelant réel.** `trusk-api/routes/bridges/ordermission.js` fait `getOrderMissionSearch(ctx.queryparsed)` — un pass-through total. Les logs de order-mission montrent alors le `user-agent` de trusk-api (`axios/1.18.1`) et pas celui du vrai client, ce qui envoie chercher un service Node inexistant. Signature du bridge : un `authorId=<id>` dans la query, injecté par `middlewares/auth.js:23` et que la cible ignore.
   - **la version d'axios identifie le service** plus sûrement que `x-origin-service`, que les libs anciennes ne posent pas.

3. **Corriger chaque consommateur, et vérifier sur `origin/master`** (pas le working tree) que le périmètre est clos.

4. **MEP du producteur**, puis surveillance immédiate :
   - le **nouveau** filtre doit monter (`"filter.<nouveau_nom>"`), l'**ancien** doit tomber au volume légitime résiduel ;
   - un **effondrement vers 0** de l'ancien filtre chez un consommateur qui a un repli légitime = ce consommateur redécroche ;
   - en base, compter les lignes **orphelines** (les deux colonnes NULL) créées après la MEP : c'est la régression propre au retrait de la double écriture. Et toute ligne portant encore les deux colonnes = un pod de l'ancienne image est revenu.

5. **Garder la surveillance ≥ 24 h** pour les appelants rares. L'ordo CCD ne faisait que ~28 appels/24 h : son absence sur 2 h ne prouve rien.

## Ne pas retirer la colonne du whitelist « pour forcer les appelants »

`trusk_order_id` **reste** dans `filterableColumns`/`searchableColumns` d'order-mission exprès : c'est le seul lien d'une ligne sur contrat non migré, et le split d'IN-731 est le **modèle permanent**, pas une transition. Elle partira avec le legacy. La retirer ne lèverait rien de toute façon (cf. `throwOnInvalidFilter` off) — ça rendrait juste les pannes muettes.

## Latence de détection : le sondage ne perd rien, il retarde

Pas de clés API Datadog en local (ni `DD_API_KEY`/`DD_APP_KEY`, ni `~/.datadog*`) → Datadog n'est accessible que par le MCP `toolhive-tech`, donc pas depuis un shell, donc **pas de Monitor qui streame**. La surveillance est forcément du sondage par cron. Comme chaque sondage regarde en arrière sur une fenêtre bien plus large que sa période (30 min de fenêtre pour 3 min de période), **rien n'est manqué** : seule l'alerte est retardée. Ne pas confondre les deux quand on annonce une couverture.

`tech-datadog_notebooks` est exposé par le MCP mais répond **`Authorization denied: Forbidden`** en lecture comme en écriture — on ne peut pas y ranger un runbook.
