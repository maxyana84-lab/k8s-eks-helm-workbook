# 5. RBAC & Security

CI runs the exercises with `scripts/test-05.sh` (job `section-05`); every permission is checked with `kubectl auth can-i`.

| Exercise | Files |
|---|---|
| 5.1 ServiceAccount + Role + RoleBinding | `5.1-rbac-dev.yaml` |
| 5.2 ClusterRole for node access | `5.2-clusterrole-nodes.yaml` |
| 5.3 Pod Security Admission | `5.3-namespace-restricted.yaml`, `5.3-privileged-pod.yaml`, `5.3-compliant-pod.yaml` |

## 5.1 Role and RoleBinding

`deploy-bot` (ServiceAccount in `dev`) can `get/list/watch` Pods and Deployments in `dev` and nothing else. Deployments are in
the API group `apps`, Pods in the core group (`""`): that is why the Role has two rules.

```bash
SA=system:serviceaccount:dev:deploy-bot
kubectl auth can-i list pods        --as=$SA -n dev        # yes
kubectl auth can-i delete pods      --as=$SA -n dev        # no
kubectl auth can-i list pods        --as=$SA -n default    # no: a Role works in its own namespace only
kubectl auth can-i --list           --as=$SA -n dev
```

## 5.2 ClusterRole for a group

Nodes and PersistentVolumes have no namespace, so they need a **ClusterRole**, and to give it cluster-wide a
**ClusterRoleBinding** (a RoleBinding of a ClusterRole would grant it in one namespace only, where nodes do not exist).
The subject is the group `ops-team`: Kubernetes has no user or group objects; the identity comes from the authenticator
(on EKS from the `aws-auth` ConfigMap or access entries). `--as` and `--as-group` impersonate it:

```bash
kubectl auth can-i list nodes --as=alice --as-group=ops-team    # yes
kubectl auth can-i list nodes --as=alice                        # no
```

## 5.3 Pod Security Admission

The label `pod-security.kubernetes.io/enforce: restricted` on the `prod` namespace makes the API server reject Pods that
do not satisfy the Pod Security Standard. The privileged Pod is rejected with
`violates PodSecurity "restricted:latest": privileged ...`. The compliant Pod has, as the workbook hints:

- `runAsNonRoot: true` (and a user ID, because the image does not say one),
- `capabilities.drop: ["ALL"]`,
- `seccompProfile.type: RuntimeDefault`,
- `allowPrivilegeEscalation: false` (also required by `restricted`).

The other modes are `warn` (the Pod is created with a warning) and `audit` (an audit log entry): a safe way to try a stricter
level before enforcing it.

## What was verified

All checks run on kind v1.31: the allowed and the denied `can-i` answers, and the rejection of the privileged Pod with the
`restricted:latest` message.
