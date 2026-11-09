#!/usr/bin/env bash
# Section 10, the parts that need only a plain kind cluster: 10.1 blue/green and 10.3 probes.
set -euo pipefail
cd "$(dirname "$0")/../10-production-patterns"
source ../scripts/lib.sh

step "10.1 blue/green"
kubectl apply -f 10.1-bluegreen.yaml
kubectl rollout status deployment/app-blue --timeout=180s
kubectl rollout status deployment/app-green --timeout=180s
kubectl run client --image=busybox:1.36 --restart=Never -- sleep 600
kubectl wait --for=condition=Ready pod/client --timeout=120s
ask() { kubectl exec client -- wget -qO- -T 2 http://myapp; }
[[ "$(ask)" == *blue* ]] || fail "the Service must answer with blue first"
# a client that sends 150 requests (about 15 s) while the selector is switched
kubectl exec -i client -- sh >/tmp/switch.out 2>&1 <<'EOS' &
b=0; g=0; f=0; i=0
while [ $i -lt 150 ]; do
  out=$(wget -qO- -T 2 http://myapp) || { f=$((f+1)); out=""; }
  case "$out" in *blue*) b=$((b+1));; *green*) g=$((g+1));; esac
  i=$((i+1)); sleep 0.1
done
echo "blue=$b green=$g failed=$f"
EOS
loop=$!
sleep 3
kubectl patch svc myapp -p '{"spec":{"selector":{"app":"myapp","version":"green"}}}'
wait $loop
cat /tmp/switch.out
res=$(tail -1 /tmp/switch.out)
[[ "$res" == *"failed=0" ]] || fail "requests failed during the switch: $res"
blue=${res#blue=}; blue=${blue%% *}
green=${res#*green=}; green=${green%% *}
[ "$blue" -gt 0 ] || fail "no request was served by blue before the switch"
[ "$green" -gt 0 ] || fail "no request was served by green after the switch"
[[ "$(ask)" == *green* ]] || fail "the Service must answer with green after the switch"
# rollback is the same switch back
kubectl patch svc myapp -p '{"spec":{"selector":{"app":"myapp","version":"blue"}}}'
back() { [[ "$(ask)" == *blue* ]]; }
retry 30 back || fail "the rollback to blue did not work"
kubectl delete pod client --wait=true
kubectl delete -f 10.1-bluegreen.yaml --wait=true

step "10.3 probes"
kubectl apply -f 10.3-probes.yaml
pod_name() { kubectl get pod -l app=slow-app -o jsonpath='{.items[0].metadata.name}'; }
running() { [ "$(kubectl get pod -l app=slow-app -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" = "Running" ]; }
retry 60 running || fail "the Pod is not Running"
pod=$(pod_name)
# the app needs 20 s to start: the Pod is Running but not Ready, and it is NOT restarted (the startupProbe waits)
[ "$(kubectl get pod "$pod" -o jsonpath='{.status.containerStatuses[0].ready}')" = "false" ] || fail "the slow app must not be Ready yet"
sleep 8
[ "$(kubectl get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')" = "0" ] || fail "the slow start was killed: the startupProbe does not protect it"
kubectl wait --for=condition=Ready "pod/$pod" --timeout=120s
[ "$(kubectl get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')" = "0" ] || fail "restarted during the start"
spec() { kubectl get pod "$pod" -o jsonpath="$1"; }
[ "$(spec '{.spec.containers[0].startupProbe.failureThreshold}')" = "30" ]         || fail "startupProbe failureThreshold is not 30"
[ "$(spec '{.spec.containers[0].livenessProbe.periodSeconds}')" = "10" ]           || fail "livenessProbe does not run every 10 s"
[ -n "$(spec '{.spec.containers[0].livenessProbe.httpGet.path}')" ]                 || fail "livenessProbe is not an HTTP check"
[ "$(spec '{.spec.containers[0].readinessProbe.tcpSocket.port}')" = "80" ]          || fail "readinessProbe is not a TCP check"
# break the app: nginx answers 403 without index.html, the liveness probe fails 3 times and the container is restarted
kubectl exec "$pod" -- sh -c 'mv /usr/share/nginx/html/index.html /tmp/index.html'
restarted() { [ "$(kubectl get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')" -ge 1 ]; }
retry 150 restarted || fail "the failing liveness probe did not restart the container"
d=$(kubectl describe pod "$pod")
grep -q "Liveness probe failed" <<<"$d" || fail "describe does not show the liveness failure"
kubectl delete -f 10.3-probes.yaml --wait=true

echo; echo "Section 10 (blue/green and probes): all exercises passed"
