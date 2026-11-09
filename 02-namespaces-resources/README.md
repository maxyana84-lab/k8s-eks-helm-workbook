# 2. Namespaces & Resource Management

CI runs all three exercises on a kind cluster with `scripts/test-02.sh` (job `section-02`).

| Exercise | Files |
|---|---|
| 2.1 Create and switch namespaces | `2.1-namespaces.yaml`, `2.1-nginx.yaml` |
| 2.2 ResourceQuota | `2.2-resourcequota.yaml` |
| 2.3 LimitRange defaults | `2.3-limitrange.yaml`, `2.3-pod-no-resources.yaml` |

## 2.1 Namespaces and the default namespace of the context

```bash
kubectl apply -f 2.1-namespaces.yaml                       # dev, staging, prod
kubectl config set-context --current --namespace=dev       # dev is now the default
kubectl config view --minify -o jsonpath='{..namespace}'   # check
for ns in dev staging prod; do kubectl apply -n $ns -f 2.1-nginx.yaml; done
kubectl get pods                                           # only dev, because of the context
kubectl get pods -A                                        # all namespaces
```

`2.1-nginx.yaml` has no namespace on purpose: the same file is applied with `-n` three times.
To go back: `kubectl config set-context --current --namespace=default`.

## 2.2 ResourceQuota

`dev-quota` in `dev`: 5 Pods, 5 Services, `requests.cpu` 2, `requests.memory` 4Gi. "CPU total" and "memory total" of the
exercise are the **sums of the container requests**. What happens when it is exceeded:

| Over the quota | What you see |
|---|---|
| Pod created directly | `kubectl apply` fails: `forbidden: exceeded quota: dev-quota, requested: requests.cpu=3, used: ..., limited: requests.cpu=2` |
| Pods of a Deployment | the Deployment is created, but the ReplicaSet cannot create the Pods: condition `ReplicaFailure=True` with the same message (look at `kubectl describe rs`) |
| 6th Service | `kubectl create service` fails with `exceeded quota` |

```bash
kubectl describe resourcequota dev-quota -n dev     # Used / Hard
```

Once a quota covers CPU or memory, every Pod of the namespace must declare requests (or get them from a LimitRange,
see 2.3), otherwise it is rejected.

## 2.3 LimitRange defaults

The LimitRange gives each container without resources a request of 100m CPU / 128Mi memory and a limit of 500m / 512Mi.
`defaultRequest` is the request, `default` is the limit. It acts at admission only: Pods that exist already are not changed.

```bash
kubectl apply -f 2.3-limitrange.yaml
kubectl apply -f 2.3-pod-no-resources.yaml
kubectl get pod no-resources -n dev -o jsonpath='{.spec.containers[0].resources}'
```

## What was verified

All exercises run on kind v1.31 with assertions (the quota rejections, the ReplicaFailure condition, the defaults).
