# 1. Core Kubernetes Objects

Manifests for exercises 1.1-1.8. CI runs all of them on a kind cluster (1 control-plane, 2 workers)
with `scripts/test-01.sh`, which asserts the result of each exercise.

| Exercise | File | Level |
|---|---|---|
| 1.1 Pod from scratch | `1.1-nginx-pod.yaml` | Beginner |
| 1.2 Multi-container Pod (sidecar) | `1.2-sidecar-pod.yaml` | Intermediate |
| 1.3 Deployment, rolling update | `1.3-webapp-deployment.yaml` | Beginner |
| 1.4 ConfigMap and Secret | `1.4-config-secret.yaml` | Beginner |
| 1.5 Service types | `1.5-services.yaml` | Beginner |
| 1.6 Job and CronJob | `1.6-job-cronjob.yaml` | Intermediate |
| 1.7 DaemonSet | `1.7-daemonset.yaml` | Intermediate |
| 1.8 StatefulSet + headless Service | `1.8-statefulset.yaml` | Advanced |

Run them yourself on any cluster (kind, minikube, EKS):

```bash
kind create cluster --config scripts/kind-config.yaml   # optional, a local cluster
scripts/test-01.sh                                      # applies, checks and cleans up every exercise
```

## 1.1 Pod from scratch

```bash
kubectl apply -f 1.1-nginx-pod.yaml
kubectl get pod nginx-pod -o wide
kubectl describe pod nginx-pod        # Events show why a Pod is Pending
```

## 1.2 Sidecar

`app` appends `date` to `/var/log/app.log` every 2 s; `sidecar` does `tail -F` on the same file.
Both mount one `emptyDir`, which lives as long as the Pod. The sidecar runs `touch` first because
containers of a Pod start without a guaranteed order and the file may not exist yet.

```bash
kubectl logs sidecar-pod -c sidecar
```

## 1.3 Rolling update and rollback

`maxSurge: 1, maxUnavailable: 0` means a new Pod is created first, and an old one is removed only when
the new one is Ready: there are always 3 available Pods. A `readinessProbe` is needed for that to be true.

```bash
kubectl apply -f 1.3-webapp-deployment.yaml
kubectl set image deployment/webapp nginx=nginx:1.25
kubectl rollout status deployment/webapp
kubectl rollout history deployment/webapp
kubectl rollout undo deployment/webapp            # back to nginx:1.24
```

## 1.4 ConfigMap and Secret

The ConfigMap is injected as env vars (`envFrom`), the Secret is mounted as files in `/etc/secrets`
(one file per key). **The Secret is not in Git**: create it with a command and your own value
(the workbook uses a demo value `s3cret`):

```bash
kubectl create secret generic app-secret --from-literal=DB_PASSWORD='<your value>'
kubectl apply -f 1.4-config-secret.yaml
kubectl exec config-demo -- env | grep -E 'APP_ENV|LOG_LEVEL'
kubectl exec config-demo -- cat /etc/secrets/DB_PASSWORD
```

Hint of the workbook: Secrets are only base64-encoded, not encrypted. `kubectl get secret app-secret -o yaml`
shows the value after `base64 -d`. Encryption at rest has to be turned on separately (KMS on EKS).

## 1.5 Service types

| Type | Reachable from | How it was tested |
|---|---|---|
| ClusterIP | inside the cluster | `wget` from a temporary Pod |
| NodePort 30080 | any node IP on port 30080 | `curl` on a kind node |
| LoadBalancer | the Internet, through a cloud load balancer | creates an AWS ELB/NLB on EKS |

On kind there is no cloud controller, so the LoadBalancer Service stays with `EXTERNAL-IP <pending>`
(CI only checks the type and the endpoints). On EKS it gets a DNS name of a load balancer.

## 1.6 Job and CronJob

`backoffLimit: 4` is the number of retries of failed Pods; `activeDeadlineSeconds: 100` kills the Job after
100 s no matter what. The CronJob `*/5 * * * *` runs every 5 minutes; to test it without waiting:
`kubectl create job --from=cronjob/print-date manual-1`.

```bash
kubectl logs job/pi
```

## 1.7 DaemonSet

One Pod per node. Control-plane nodes have the taint `node-role.kubernetes.io/control-plane:NoSchedule`,
so a toleration is needed to run there too (the workbook hint). `/var/log` is mounted read-only from the host.
The workbook image `fluentd:latest` is replaced with a pinned tag.

```bash
kubectl get pods -l app=log-collector -o wide     # one Pod per node
```

## 1.8 StatefulSet + headless Service

`clusterIP: None` makes the Service headless: DNS returns the Pod addresses and every Pod gets its own name
`redis-cluster-N.redis-headless.<namespace>.svc.cluster.local`. `volumeClaimTemplates` creates one 1Gi PVC per
replica (`data-redis-cluster-N`), and the PVC stays when the Pod is recreated. PVCs are **not** deleted with the
StatefulSet; delete them yourself (`kubectl delete pvc -l app=redis-cluster`).

These are three independent Redis servers with stable names and storage, which is what the exercise asks for.
A real Redis cluster needs `redis-cli --cluster create` on top.

```bash
kubectl exec busybox -- nslookup redis-cluster-0.redis-headless.default.svc.cluster.local
```

## What was verified

- All manifests: `kubeconform` against the Kubernetes 1.31 schemas (CI job `validate`).
- Exercises 1.1-1.8 on kind v1.31 with assertions (CI job `section-01`).
- Not verified: the LoadBalancer of 1.5 on a real cloud (needs EKS).
