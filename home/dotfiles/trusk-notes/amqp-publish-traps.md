# AMQP publish traps — silent drops, and ruling out the flag first

Triggers: publish resolves OK but the queue stays empty · consumer never fires · scheduled/delayed work never runs · `AmqpPublisher.publish()` · `lib-messenger` · `AmqpExchangeType.DIRECT` · messages discarded with no error · `rabbitmqctl list_queues` times out · "is this flag actually on in staging?"

## `AmqpPublisher.publish()` cannot reach a DIRECT exchange — and fails silently

`lib-messenger/utils.js` maps (DIRECT, PUBLISH) to the `q` qualifier, which `lib-amqp-connector` turns into a `sendToQueue` on the **default** exchange. With no queue of that name and no `mandatory` flag, the broker discards the message — **and the publish promise resolves successfully**. No throw, no log, no metric, no dead-letter.

Subscribing to a DIRECT exchange works fine, so consumers, bindings and TTLs all look correct on inspection. Only the publish path is broken.

Signature to recognise: the "scheduled/published X" log line fires at the expected rate, every queue sits at 0 messages with healthy consumer counts, and the downstream side effect never happens — in any environment, since the feature shipped.

**Fix**: declare the exchange `TOPIC`. Every literal routing key is a valid TOPIC pattern, so no routing-key changes are needed and consumers keep working.

Real case — state-status IN-589 mission delay detection: all three delay exchanges (`state-status.delay.{in,router,fire}`) were declared DIRECT. Every delay check was dropped in every env from the feature shipping (PR #128, 2026-07-03) until the fix (PR #140, merged 2026-09-01). Prod logged 230 scheduled checks over 26 minutes with zero publishes recorded on any of the three exchanges and not a single `RISK`/`DELAY_DETECTED` status ever written. Nine weeks live, zero output, zero errors.

## Inspect the topology before blaming the code

```bash
CTX=trusk-staging-ts
kubectl --context $CTX -n staging exec rabbitmq-cluster-server-0 -c rabbitmq -- \
  rabbitmqctl list_queues --vhost staging name messages consumers | grep <feature>
kubectl --context $CTX -n staging exec rabbitmq-cluster-server-0 -c rabbitmq -- \
  rabbitmqctl list_exchanges --vhost staging name | grep <feature>
```

- The vhost is **`staging`**, not `/`. Omit `--vhost staging` and you get `Timeout: 60.0 seconds ... Listing queues for vhost /` and learn nothing. Cluster has vhosts `/` and `staging`.
- Pass `-c rabbitmq` — the pod also has a `setup-container` init and kubectl prints a "Defaulted container" warning into your output otherwise.
- **`rabbitmqadmin` and `curl` are not in the image**, so the management HTTP API (`:15672/api/exchanges/...`, where `message_stats.publish_in` lives) is not reachable from inside the pod. Port-forward if you need publish counters.

Reading the result: queues at 0 messages **with** consumers ≥ 1 means the topology is fine and nothing is arriving → suspect the publish side, not the consumer.

## Rule out the feature flag from inside the pod

Two traps here, both of which fake a "flagd is broken / off" conclusion:

1. **flagd is a *native sidecar*, so it is invisible in the container list.** The openfeature operator injects it as an `initContainer` with `restartPolicy: Always` — not as a regular container. So `{.spec.containers[*].name}` and `{.status.containerStatuses[*].name}` both show only the app container, while `READY` says `2/2` and port 8013 is live and serving. Never conclude "no flagd" from the container list; look here instead:

   ```bash
   kubectl -n staging get pod <pod> -o jsonpath='{range .spec.initContainers[*]}{.name}{" restartPolicy="}{.restartPolicy}{"\n"}{end}'
   # state-status-pgm restartPolicy=
   # flagd          restartPolicy=Always     ← the sidecar
   ```

   This also means the documented "two containers" pod shape (init `<svc>-pgm` + main `<svc>`) is really three on flagd-enabled services, and `kubectl logs <pod> -c flagd` is how you read its startup.
2. **The repo's `deployment/flagd/featureflag.yaml` is not the live value.** `defaultVariant` there is usually `off` while the cluster has been flipped `on` by hand.

Evaluate the flag for real, from inside the pod:

```bash
kubectl --context $CTX -n staging exec <pod> -c <svc> -- node -e '
const http=require("http");
const body=JSON.stringify({flagKey:"<flag_key>",context:{}});
const req=http.request({host:"127.0.0.1",port:8013,path:"/flagd.evaluation.v1.Service/ResolveBoolean",
  method:"POST",headers:{"content-type":"application/json","content-length":Buffer.byteLength(body)}},
  r=>{let d="";r.on("data",c=>d+=c);r.on("end",()=>console.log(r.statusCode,d))});
req.on("error",e=>console.log("ERR",e.message));req.end(body);'
# → 200 {"value":true, "reason":"STATIC", "variant":"on", "metadata":{}}
```

Live values are in the **`flagd` namespace**, one CR per service:

```bash
kubectl --context $CTX -n flagd get featureflag
kubectl --context $CTX -n flagd get featureflag <svc>-flags -o json \
  | python3 -c "import sys,json;print({k:v.get('defaultVariant') for k,v in json.load(sys.stdin)['spec']['flagSpec']['flags'].items()})"
```

## Debug-log levels hide the no-op reasons

Services following this pattern log every skip reason at `debug` (`flag OFF`, `no longer at risk`, `window changed`, `already detected`). Staging runs `LOGGER_LEVEL=http`, which suppresses all of them — you see the "scheduled" line and then silence, which looks identical to a crash. Raise the level on the deployment (with ArgoCD `selfHeal: false`) before concluding anything from the absence of logs. See [prod-vs-staging-prerequisites](prod-vs-staging-prerequisites.md) and the temp-debug recipe in the main CLAUDE.md.
