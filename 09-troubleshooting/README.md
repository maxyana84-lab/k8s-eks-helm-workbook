# 9. Troubleshooting & Debugging

Each exercise has a **broken** manifest and a **fix**. CI (`scripts/test-09.sh`, on kind with Calico so that NetworkPolicy works)
applies the broken one, runs the diagnosis commands, asserts that they show the root cause, then applies the fix.

| Exercise | Files |
|---|---|
| 9.1 CrashLoopBackOff | `9.1-crashloop-broken.yaml`, `9.1-crashloop-fixed.yaml` |
| 9.2 Pending Pod | `9.2-pending-broken.yaml`, `9.2-pending-fixed.yaml` |
| 9.3 Service connectivity | `9.3-service-broken.yaml`, `9.3-networkpolicy.yaml` |
| 9.4 Ephemeral debug containers | `9.4-distroless-pod.yaml` |

A general order: `kubectl get` (the status) -> `kubectl describe` (the Events at the bottom) -> `kubectl logs` (and `--previous`) -> a
shell or a debug container in the Pod.

## 9.1 CrashLoopBackOff

The container starts, fails (exit code 1) and Kubernetes restarts it with a growing delay (10 s, 20 s, ... up to 5 minutes): that
waiting is the status `CrashLoopBackOff`; it is the symptom, not the cause.

```bash
kubectl get pod crashing                  # CrashLoopBackOff, RESTARTS 3 ...
kubectl describe pod crashing             # Last State: Terminated, Exit Code: 1; Events: Back-off restarting failed container
kubectl logs crashing                     # may be empty or of the new run
kubectl logs crashing --previous          # the run that failed: "fatal: cannot read /etc/app/app.conf"
```

Exit codes: 1 = the application failed, 137 = killed (OOM or `kill -9`), 139 = segmentation fault, 126/127 = the command cannot be
executed / is not found. The fix here: provide the config file (a ConfigMap mounted at `/etc/app`).

## 9.2 Pending Pod

`Pending` with `NODE <none>` means that the scheduler found no node. The reason is in the Events:
`0/3 nodes are available: 3 Insufficient memory` (and for the control-plane node: a taint). Fix: a request that fits
(`64Mi`). Other causes: a `nodeSelector` or affinity that no node satisfies, a taint without a toleration, a PVC that is not bound
(`kubectl get pvc`), a quota (the Pod is not even created then).

## 9.3 Service connectivity ("connection refused")

The chain of the workbook, with the faults placed in it one after the other:

| Step | Command | What it shows here | Fix |
|---|---|---|---|
| (1) endpoints | `kubectl get endpoints web-svc` | `<none>`: no Pod behind the Service | find out why |
| (2) labels vs selector | `kubectl get pods --show-labels` and `kubectl get svc web-svc -o yaml` | the selector is `app: wb`, the Pods have `app: web` | fix the selector |
| (3) readiness | `kubectl describe pod` | `Readiness probe failed` on port 8081: the Pod is listed under `notReadyAddresses` and gets no traffic | fix the probe port to 80 |
| (4) port-forward | `kubectl port-forward svc/web-svc 8080:80` and `curl localhost:8080` | works: the Service and the Pod are fine, the problem is between the client and them | |
| (5) NetworkPolicy | `kubectl get networkpolicy` | a default-deny policy: the request times out (a policy drops packets, a missing endpoint refuses them) | add a policy that allows the client |

Useful to tell the faults apart: **refused** (immediately) = nothing listens or no endpoints; **timeout** = something drops the packets
(a policy, a security group, a wrong IP). Step (5) needs a CNI that enforces policies, hence Calico in CI.

## 9.4 Ephemeral debug containers

A distroless (or `scratch`) image has no shell, so `kubectl exec ... -- sh` fails with `executable file not found`. `kubectl debug` adds
an **ephemeral container** with the tools you choose to the running Pod, without restarting it:

```bash
kubectl debug -it distroless --image=busybox:1.36 --target=pause
# inside: ps (sees the process of the target container), nslookup, wget, nc ...
```

`--target` joins the process namespace of that container; the network namespace is shared by the whole Pod anyway, so the tools see
the Pod's own network. An ephemeral container cannot be removed or changed; it ends with the Pod. The result is visible in
`kubectl get pod distroless -o jsonpath='{.spec.ephemeralContainers}'`. CI runs it without a terminal and reads the logs of the debug container.

## What was verified

All four exercises run on kind (Calico) with assertions on the symptoms (CrashLoopBackOff with the root cause in `--previous`, FailedScheduling
with `Insufficient memory`, empty endpoints / notReady / timeout under a policy, an ephemeral container that sees the target process) and on the fixes.
