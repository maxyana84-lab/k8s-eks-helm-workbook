#!/usr/bin/env bash
# Section 9. Needs a cluster that enforces NetworkPolicy (9.3 step 5): scripts/kind-config-networking.yaml + setup-networking-cluster.sh.
set -euo pipefail
cd "$(dirname "$0")/../09-troubleshooting"
source ../scripts/lib.sh

step "9.1 CrashLoopBackOff"
kubectl apply -f 9.1-crashloop-broken.yaml
crashloop() { [ "$(kubectl get pod crashing -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}')" = "CrashLoopBackOff" ]; }
retry 180 crashloop || fail "the Pod does not reach CrashLoopBackOff"
[ "$(kubectl get pod crashing -o jsonpath='{.status.containerStatuses[0].restartCount}')" -ge 1 ] || fail "no restart was counted"
# the root cause is in the log of the previous run
prev=$(kubectl logs crashing --previous)
echo "$prev"
grep -q "cannot read /etc/app/app.conf" <<<"$prev" || fail "kubectl logs --previous does not show the root cause"
desc=$(kubectl describe pod crashing)
grep -q "Exit Code:    1" <<<"$desc" || grep -q "Exit Code: *1" <<<"$desc" || fail "describe does not show the exit code"
grep -q "Back-off restarting failed container" <<<"$desc" || fail "describe does not show the back-off event"
kubectl delete -f 9.1-crashloop-broken.yaml --wait=true
kubectl apply -f 9.1-crashloop-fixed.yaml
kubectl wait --for=condition=Ready pod/crashing --timeout=120s
[ "$(kubectl get pod crashing -o jsonpath='{.status.containerStatuses[0].restartCount}')" = "0" ] || fail "the fixed Pod restarts"
kubectl delete -f 9.1-crashloop-fixed.yaml --wait=true

step "9.2 Pending Pod"
kubectl apply -f 9.2-pending-broken.yaml
sleep 5
[ "$(kubectl get pod hungry -o jsonpath='{.status.phase}')" = "Pending" ] || fail "the Pod is not Pending"
event_seen() { local d; d=$(kubectl describe pod hungry); grep -q "Insufficient memory" <<<"$d"; }
retry 60 event_seen || fail "describe does not show FailedScheduling / Insufficient memory"
kubectl describe pod hungry | tail -5
kubectl delete -f 9.2-pending-broken.yaml --wait=true
kubectl apply -f 9.2-pending-fixed.yaml
kubectl wait --for=condition=Ready pod/hungry --timeout=120s
kubectl delete -f 9.2-pending-fixed.yaml --wait=true

step "9.3 Service connectivity"
kubectl apply -f 9.3-service-broken.yaml
kubectl wait --for=condition=Ready pod/client -n debug-svc --timeout=180s
reach() { kubectl exec -n debug-svc client -- wget -qO /dev/null -T 3 http://web-svc >/dev/null 2>&1; }
# the symptom
if reach; then fail "the Service must not answer yet"; fi
# (1) endpoints
[ -z "$(kubectl get endpoints web-svc -n debug-svc -o jsonpath='{.subsets}')" ] || fail "the endpoints must be empty"
# (2) labels and selector
[ "$(kubectl get svc web-svc -n debug-svc -o jsonpath='{.spec.selector.app}')" != "$(kubectl get pod -n debug-svc -l app=web -o jsonpath='{.items[0].metadata.labels.app}')" ] || fail "selector and labels must differ"
kubectl patch svc web-svc -n debug-svc -p '{"spec":{"selector":{"app":"web"}}}'
# (3) the Pod is matched now, but it is not Ready: the readiness probe is wrong
notready() { [ -n "$(kubectl get endpoints web-svc -n debug-svc -o jsonpath='{.subsets[0].notReadyAddresses[0].ip}')" ]; }
retry 60 notready || fail "the Pod must be listed as notReadyAddresses"
if reach; then fail "a Pod that is not Ready must not receive traffic"; fi
d=$(kubectl describe pod -n debug-svc -l app=web)
grep -q "Readiness probe failed" <<<"$d" || fail "describe does not show the failed readiness probe"
kubectl patch deployment web -n debug-svc --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'
kubectl rollout status deployment/web -n debug-svc --timeout=180s
retry 60 reach || fail "the Service does not answer after the selector and the probe are fixed"
# (4) port-forward: the same Service from outside the cluster, no client Pod, no network policy involved
kubectl port-forward -n debug-svc svc/web-svc 18080:80 >/tmp/pf.log 2>&1 &
pf=$!
pf_ok() { local b; b=$(curl -fsS -m 3 http://localhost:18080) && grep -q "Welcome to nginx" <<<"$b"; }
retry 30 pf_ok || { kill $pf; fail "port-forward does not reach the Service"; }
kill $pf
# (5) NetworkPolicies
kubectl apply -f 9.3-networkpolicy.yaml
kubectl delete networkpolicy allow-client-to-web -n debug-svc     # first only the default deny
denied() { if reach; then return 1; else return 0; fi; }
retry 90 denied || fail "the default-deny policy does not block the client"
kubectl get networkpolicy -n debug-svc
kubectl apply -f 9.3-networkpolicy.yaml
retry 90 reach || fail "the client does not get through after the allow policy"
kubectl delete namespace debug-svc --wait=true

step "9.4 ephemeral debug container"
kubectl apply -f 9.4-distroless-pod.yaml
kubectl wait --for=condition=Ready pod/distroless --timeout=180s
out=$(kubectl exec distroless -- sh 2>&1 || true)
echo "$out"
grep -qi "not found" <<<"$out" || fail "the distroless Pod must have no shell"
kubectl debug distroless --image=busybox:1.36 --target=pause --container=debugger -- \
  sh -c 'ps; nslookup kubernetes.default.svc.cluster.local; wget -q -O- -T 3 http://kubernetes.default.svc.cluster.local:443 >/dev/null 2>&1; echo debug-done'
debug_done() { local l; l=$(kubectl logs distroless -c debugger 2>/dev/null) && grep -q "debug-done" <<<"$l"; }
retry 90 debug_done || fail "the debug container did not finish"
logs=$(kubectl logs distroless -c debugger)
echo "$logs"
[ "$(kubectl get pod distroless -o jsonpath='{.spec.ephemeralContainers[0].name}')" = "debugger" ] || fail "no ephemeral container in the Pod spec"
grep -q "/pause" <<<"$logs" || fail "the debug container does not see the process of the target container (--target)"
grep -q "Address" <<<"$logs" || fail "DNS does not work in the debug container"
[ "$(kubectl get pod distroless -o jsonpath='{.status.containerStatuses[0].restartCount}')" = "0" ] || fail "the application container was restarted"
kubectl delete -f 9.4-distroless-pod.yaml --wait=true

echo; echo "Section 9: all exercises passed"
