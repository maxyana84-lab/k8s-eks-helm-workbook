# 6. Scheduling & Scaling

CI runs the exercises with `scripts/test-06.sh` on a kind cluster with 2 workers (job `section-06`).

| Exercise | Files |
|---|---|
| 6.1 Node affinity and anti-affinity | `6.1-ssd-pod.yaml`, `6.1-spread-deployment.yaml` |
| 6.2 Taints and tolerations | `6.2-no-toleration.yaml`, `6.2-toleration-pod.yaml` |
| 6.3 HPA | `6.3-hpa.yaml`, `6.3-load.yaml` |
| 6.4 PodDisruptionBudget | `6.4-pdb.yaml` |

## 6.1 Affinity

`kubectl label node <node> disk=ssd`. `requiredDuringSchedulingIgnoredDuringExecution` is a hard rule at scheduling time
(a Pod with no matching node stays Pending); "IgnoredDuringExecution" means that a Pod already running stays if the label is
removed. `preferred...` would only add weight. Pod anti-affinity with `topologyKey: kubernetes.io/hostname` keeps two Pods
`app=spread` off the same node; with `required` and more replicas than nodes, the extra replicas stay Pending.

## 6.2 Taints and tolerations

A taint repels Pods, a toleration allows a Pod to be on the tainted node, it does not attract it. So `tolerating-pod` also has a
`nodeSelector` (`env=prod`) to land there. Taint effects: `NoSchedule` (new Pods only), `PreferNoSchedule`, `NoExecute`
(evicts the running Pods too).

```bash
kubectl taint node <node> env=prod:NoSchedule
kubectl taint node <node> env=prod:NoSchedule-     # the trailing - removes it
```

## 6.3 HPA

1. metrics-server (on kind with `--kubelet-insecure-tls`, kubelets have self-signed certificates; on EKS no flag is needed).
2. The Deployment must declare CPU **requests**: the target of 50% is a share of the request, not of the node.
3. The load: `load-generator` calls the service in a loop. CI waits until the HPA scales above 2 replicas.

Scale-down is slow on purpose: the HPA waits 5 minutes (`stabilizationWindowSeconds`) so that the replicas do not flap, so this
is not asserted in CI. The php-apache tutorial image has only the `latest` tag, the one exception to the "pinned tags" rule here.

## 6.4 PodDisruptionBudget

`minAvailable: 2` with 3 replicas means 1 Pod may be down at a time (`disruptionsAllowed: 1`). `kubectl drain` evicts through
the Eviction API, which respects the budget. CI shows both sides:

- with `minAvailable: 3` the drain is blocked: `Cannot evict pod as it would violate the pod's disruption budget`;
- with `minAvailable: 2` the drain succeeds, one Pod after another, and no Pod stays on the node.

A PDB protects only against **voluntary** disruptions (drain, node upgrades), not against crashes or a node failing.
`kubectl uncordon <node>` makes the node schedulable again.
