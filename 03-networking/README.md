# 3. Networking & Ingress

CI runs the exercises with `scripts/test-03.sh` (job `section-03`) on a kind cluster with **Calico**
(`scripts/kind-config-networking.yaml`) and **ingress-nginx** (`scripts/setup-networking-cluster.sh`).

| Exercise | Files |
|---|---|
| 3.1 NetworkPolicy: deny all + allow specific | `3.1-networkpolicy.yaml`, `3.1-policies.yaml` |
| 3.2 Ingress with path-based routing | `3.2-ingress.yaml` |
| 3.3 DNS debugging | `3.3-dns-debug.yaml` |

## 3.1 NetworkPolicy

`3.1-networkpolicy.yaml` creates the `prod` namespace with an API (`role=api`, port 8080, behind `api-svc`), a
`role=frontend` Pod and a `role=other` Pod. `3.1-policies.yaml` has the two policies:

1. `default-deny-ingress`: `podSelector: {}` selects every Pod, and a policy with `Ingress` and no rules allows nothing.
2. `allow-frontend-to-api`: Pods `role=api` accept TCP 8080 from Pods `role=frontend` only.

Policies are additive: the second one opens a hole in the first one.

```bash
kubectl apply -f 3.1-networkpolicy.yaml
kubectl apply -f 3.1-policies.yaml
kubectl exec -n prod frontend-pod -- wget -qO- -T 3 http://api-svc:8080   # works
kubectl exec -n prod other-pod    -- wget -qO- -T 3 http://api-svc:8080   # times out
```

**A NetworkPolicy does nothing without a CNI that enforces it.** kindnet (the default of kind) does not, so CI uses Calico.
On EKS the VPC CNI enforces policies only when its network policy feature is turned on (or with Calico/Cilium).

## 3.2 Ingress with path-based routing

`/` goes to `frontend-svc:80`, `/api` to `api-svc:8080`, with `ingressClassName: nginx`. nginx picks the longest matching
prefix, so `/api` is not caught by `/`. The path is passed to the backend unchanged (`/api`, not `/`), which is fine for the
echo server used here; a real API would need a rewrite annotation or to serve under `/api`.

```bash
curl http://localhost/        # Welcome to nginx!
curl http://localhost/api     # api-via-ingress
```

On kind the controller listens on host port 80 of the control-plane node (`extraPortMappings`). The ingress-nginx
admission webhook may reject the first `kubectl apply` for a few seconds after the controller starts, so the test retries.

## 3.3 DNS debugging

```bash
kubectl apply -f 3.3-dns-debug.yaml
kubectl exec dns-debug -- nslookup kubernetes.default.svc.cluster.local         # (1) Service FQDN
kubectl exec dns-debug -- nslookup 10-244-1-5.default.pod.cluster.local         # (2) Pod by IP: dots become dashes
kubectl exec dns-debug -- cat /etc/resolv.conf                                  # (3)
```

What `/etc/resolv.conf` of a Pod tells:

- `nameserver` is the ClusterIP of the `kube-dns` Service (CoreDNS), not the node's resolver.
- `search default.svc.cluster.local svc.cluster.local cluster.local` is why `api-svc` works in the same namespace and
  `api-svc.prod` from another one.
- `options ndots:5`: a name with fewer than 5 dots is tried with every search domain first. An external name such as
  `example.com` therefore causes several failed lookups before the real one; a trailing dot (`example.com.`) skips this.

## What was verified

All exercises run on kind v1.31 with Calico and ingress-nginx, with assertions: the frontend reaches the API, the other Pod
does not, and port 9999 stays closed; both Ingress paths answer; the three DNS lookups return the expected addresses.
