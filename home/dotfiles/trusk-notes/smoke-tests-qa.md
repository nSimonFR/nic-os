# Smoke tests QA (`trusk-automation`) — lancer, monitorer, lire

Suites end-to-end blackbox du repo `trusk-automation` (TAF). Pilotent un **vrai navigateur** contre
un staging réel et publient un rapport Slack. Trois suites, un seul mécanisme de lancement fiable :
**Argo Workflows**, namespace `awf-qa` du cluster staging.

## Les trois suites

| npm script | Fichier | Portée |
| --- | --- | --- |
| `st-bo` | `__tests__/trusk-end-to-end/bo/smoke-test-bo.test.ts` | parcours BO critiques |
| `st-e2e` | `__tests__/st-e2e/simple/smoke-test-e2e.test.ts` | bout-en-bout « Smoke Test V2 » (offre commerciale, contrats, commandes…) |
| `st-business` | `__tests__/trusk-end-to-end/business/smoke-test-business-castorama.test.ts` | parcours Business/Castorama |

`__tests__/trusk-end-to-end/bo/smoke-test-bo.services.json` mappe chaque test aux **services backend
appelés** (tags = noms de repos `trusk-official`). **Le lire avant de choisir la suite** : c'est la
seule façon de savoir laquelle couvre le service qu'on vient de déployer.

⚠️ **Piège de choix.** `st-e2e` sonne comme « le test complet » — il ne couvre en réalité que
*Offre Commerciale*, *Contrats clients* et *Sites de chargement*. Son seul « reset » concerne les
filtres de l'UI. **Il ne touche ni missions, ni tournées, ni replanification** : le lancer pour
valider un déploiement `order-mission` ou `roundtrip` ne prouve rien.

C'est **`st-bo`** qui couvre ce périmètre (121 mentions de `mission`, 103 de `roundtrip`), avec la
chaîne complète : dépôt EDI → commande → mission → tournée → points → affectation d'availability →
panel Missions → start/stop. Vérifié le 2026-09-22.

## ⚠️ Ne pas lancer en local sans grid

`npm run st-e2e` en local échoue en ~8 s avec **tous** les tests au rouge, sur une erreur
`validate (node_modules/devtools/build/utils.js)` — c'est l'absence de navigateur, pas un vrai échec
fonctionnel. Les scénarios suivants tombent ensuite en cascade sur
« *Offre jetable / contrat manquants — le scénario @createAPI doit passer avant* » : l'état est
partagé entre scénarios, donc un premier échec invalide tout le reste. **Ne jamais conclure d'un run
local rouge.**

Pour un run local malgré tout : `cd selenium-grid && ./run-grid.sh` (docker-compose, hub Selenium sur
`:4444` + nodes chrome/firefox), puis charger l'env sops :

```bash
cd ~/MyDocuments/TRUSK/trusk-automation
set -a
eval "$(sops -d env.encrypted/common.env)"
eval "$(sops -d env.encrypted/staging-staging.env)"   # ou staging-pr-qa-taf.env pour une preview
set +a
NODE_OPTIONS='--experimental-vm-modules' npx jest ./__tests__/st-e2e/simple/smoke-test-e2e.test.ts --reporters=default
```

`--reporters=default` **court-circuite `jest-slack-reporter`** — indispensable pour un run d'essai,
sinon le rapport part dans le canal QA. Le garde natif (`ENABLE_REPORT_IN_WF_SLACK` +
`SLACK_STAGING_EVENTS_CHANNEL_ID`) ne couvre qu'une partie des chemins d'envoi ; ne pas s'y fier.

## Lancement par Argo (la bonne façon)

WorkflowTemplates dans `awf-qa` (cluster staging) :

| Template | Suite |
| --- | --- |
| `smoketest-backoffice-template` | `st-bo` |
| `smoketest-e2e-template` | `st-e2e` |
| `smoketest-backoffice-template-slim-test` | variante réduite |
| `manual-wf-trigger-smoketest-with-slack` | déclenchement depuis Slack |

Paramètre unique : `STAGING_NAME` (défaut `staging` ; sinon `pr-1234`, `preprod`…). Les URLs en
dérivent : `https://{STAGING_NAME}-bo.trusk.com`, `-backoffice`, `-api`, `-tracking`.

La CLI `argo` n'est **pas installée** sur le Mac. Soumettre via kubectl avec un `workflowTemplateRef` :

```bash
export http_proxy=http://localhost:1056 https_proxy=http://localhost:1056 \
       HTTP_PROXY=http://localhost:1056 HTTPS_PROXY=http://localhost:1056
cat > /tmp/wf-smoke.yaml <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: smoketest-e2e-
  namespace: awf-qa
spec:
  workflowTemplateRef:
    name: smoketest-e2e-template
  arguments:
    parameters:
      - name: STAGING_NAME
        value: staging
YAML
kubectl --context trusk-staging-ts create -f /tmp/wf-smoke.yaml
```

Avec la CLI, si un jour elle est installée : `argo submit --from workflowtemplate/smoketest-e2e-template -n awf-qa -p STAGING_NAME=staging`.

Déclencheurs automatiques existants : sensors `sensor-github-trusk-applications` (push master) et
`sensor-github-trusk-preview-env`, webhook GitHub, et la commande Slack `/smoketest <staging>`.
Le smoke est la **dernière étape** du pipeline preview : `wake-up-namespace` →
`check-argocd-app` → `data-bo` → (`gen-data`) → smoketest.

## Monitorer

⚠️ **Le workflow poste dans le canal QA dès le démarrage**, pas seulement à la fin : une étape
`slack-notify-start` s'exécute avant le run. Un lancement d'essai est donc visible de tous — le
prévenir, ou l'assumer.

```bash
W=smoketest-e2e-xxxxx
kubectl --context trusk-staging-ts -n awf-qa get workflow $W -o jsonpath='{.status.phase}{"\n"}{.status.message}{"\n"}'
kubectl --context trusk-staging-ts -n awf-qa get pods -l workflows.argoproj.io/workflow=$W
POD=$(kubectl --context trusk-staging-ts -n awf-qa get pods -l workflows.argoproj.io/workflow=$W -o name | grep run-smoketest | head -1)
kubectl --context trusk-staging-ts -n awf-qa logs ${POD#pod/} -c main -f | sed 's/\x1b\[[0-9;]*m//g'
```

Le pod a **2 conteneurs** (`main` + le `wait` d'Argo) : sans `-c main`, kubectl se plaint ou renvoie
les logs du mauvais. Et le workflow crée **plusieurs pods** (`slack-notify-start`, `run-smoketest`) —
filtrer sur `run-smoketest`, sinon on tail un pod déjà `Completed`.

**La sortie jest est bufferisée jusqu'à la fin du run** : pendant l'exécution, `grep "Tests:"` ou
`✓/✕` ne renvoie *rien*, ce qui ne veut pas dire que ça a planté. Le seul signe de vie en direct est
le flot `INFO devtools: COMMAND elementSendKeys(...)` — c'est le navigateur qui pilote. Compter
plusieurs minutes (≫ 3 min) avant le moindre résultat agrégé.

Phases terminales : `Succeeded` / `Failed` / `Error`. Historique :
`kubectl -n awf-qa get workflows --sort-by=.metadata.creationTimestamp | grep -i smoke`.

Rapport Slack : `SLACK_QA_CHANNEL_ID` (= `SLACK_QA_CHANNEL_ID_qa_report_st` côté workflow), envoyé
par `src/slack-utils/slack-report.ts` avec captures d'écran des scénarios échoués. C'est le canal à
lire en premier — plus lisible que les logs du pod.

## Secrets et prérequis

`trusk-automation-env` (configMapRef + secretRef) fournit `BO_QA_USER_EMAIL`, `BO_QA_USER_PASSWORD`,
`SFTP_PRIVATE_KEY_VALUE`, `SLACK_QA_CHANNEL_ID_qa_report_st`. `gar-trusk` sert d'imagePullSecret pour
`trusk-automation:master`. Le ConfigMap `translation-config` est monté sur
`/translations/bo/organisations/fr.json`.

Conséquence : l'image utilisée est **`master`**, pas la branche locale. Un test modifié en local n'est
pris en compte qu'une fois mergé et l'image reconstruite.

## Lire le résultat : `Failed` ne veut pas dire cassé

Run de référence du 2026-09-22 sur `staging` (`smoketest-bo-in1040-wpwzh`) :

```
Tests: 1 failed, 4 skipped, 42 passed, 47 total   → phase Argo: Failed
```

La phase Argo passe à `Failed` dès **un seul** test rouge. Le chiffre utile est le ratio, et surtout
*quel* test tombe. Ici : `Order Details Verification › Page de suivi › en attente de RDV : le client
final corrige son nom` — `Page de suivi <id> : lien « Modifier » introuvable (page non chargée ?)`
après 40 s d'attente. C'est un timeout UI sur `front-tracking-page`, sans rapport avec les services
qu'on validait. Les 42 autres, dont toute la chaîne mission/tournée, sont verts.

Méthode : toujours extraire la ligne `Tests:` **et** les blocs `●`, puis rattacher chaque échec à son
service via `smoke-test-bo.services.json` avant de conclure à une régression.

```bash
kubectl -n awf-qa logs $POD -c main | sed 's/\x1b\[[0-9;]*m//g' | grep -aE "Tests:|^\s+●"
kubectl -n awf-qa logs $POD -c main | sed 's/\x1b\[[0-9;]*m//g' | grep -aE "^\s+✓" | sed 's/^ *//'
```

Durée observée : ~20 min pour `st-bo`, dont un « Assign availability to roundtrip » à 63 s et un
« should add appointment_sent status » à 30 s. Prévoir large.

## Ce qu'un smoke ne prouve pas

Il valide des parcours **nominaux**. Il ne rejoue **pas** les scénarios d'incident (boucles,
ré-entrance, concurrence) : ceux-là demandent un scénario dédié, écrit à la main.

Exemple vécu (IN-1040, 2026-09-22) : `st-bo` vert sur toute la chaîne mission/tournée prouve que la
**création** et l'**affectation** fonctionnent, mais aucun scénario ne *déplace* un RDV déjà pris.
Le chemin `hasAppointmentMoved` → annuler-et-recréer n'a donc jamais été emprunté — vérifiable en
cherchant les logs de branche côté service, qui restent à zéro :

```bash
kubectl -n staging logs <pod-order-mission> --since=1h \
 | grep -aoE "Replanification: cancelling|Redelivering Trusk Order|nothing to create, skipping"
```

Zéro occurrence = le code modifié n'a pas tourné, quel que soit le vert du smoke. Pour ces cas-là,
déplacer un RDV à la main en BO reste le seul test.

Et attention au volume : staging crée ~17 missions/24 h. Une sonde de non-régression du type
« 0 emballement sur 48 h » n'y démontre **rien** — le chemin fautif n'y est simplement jamais
emprunté. Voir [state-status-mirrors](state-status-mirrors.md) et
[metastable-staging](metastable-staging.md) pour la même mise en garde sur les mesures staging.
