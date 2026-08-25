# ArgoCD selfHeal vs operator-managed RBAC

Split out of `../CLAUDE.md`, which loads into every Trusk session — this does not.

## ArgoCD selfHeal + operator-managed RBAC = drift trap

When an operator appends ServiceAccount subjects to a ClusterRoleBinding at runtime (cert-manager, Velero, etc.), `selfHeal: true` reverts the additions as drift → consumers 403. Fix = `ignoreDifferences` on `/subjects` for that binding (pattern in trusk-k8s#1191). Apply preemptively for any new RBAC-self-managing operator.
