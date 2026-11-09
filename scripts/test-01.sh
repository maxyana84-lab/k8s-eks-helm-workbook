#!/usr/bin/env bash
# Runs the exercises of section 1 on the current kubectl context (a kind cluster)
# and asserts the result. Every check fails the script explicitly.
set -euo pipefail
cd "$(dirname "$0")/../01-core-objects"

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "=== $*"; }
# retry <seconds> <command...>: run the command until it succeeds
retry() {
  local secs=$1; shift
  local end=$((SECONDS + secs))
  until "$@"; do
    [ $SECONDS -lt $end ] || return 1
    sleep 2
  done
}

step "1.1 Pod nginx-pod"
kubectl apply -f 1.1-nginx-pod.yaml
kubectl wait --for=condition=Ready pod/nginx-pod --timeout=180s
[ "$(kubectl get pod nginx-pod -o jsonpath='{.spec.containers[0].image}')" = "nginx:1.25" ] || fail "wrong image"
[ "$(kubectl get pod nginx-pod -o jsonpath='{.spec.containers[0].ports[0].containerPort}')" = "80" ] || fail "port 80 not exposed"
kubectl delete -f 1.1-nginx-pod.yaml --wait=true

step "1.2 sidecar Pod"
kubectl apply -f 1.2-sidecar-pod.yaml
kubectl wait --for=condition=Ready pod/sidecar-pod --timeout=180s
check_sidecar() { kubectl logs sidecar-pod -c sidecar | grep -qE '[0-9]{4}'; }
retry 30 check_sidecar || fail "sidecar does not show the timestamps written by app"
kubectl logs sidecar-pod -c sidecar | tail -3
kubectl delete -f 1.2-sidecar-pod.yaml --wait=true

step "1.3 rolling update and rollback"
kubectl apply -f 1.3-webapp-deployment.yaml
kubectl rollout status deployment/webapp --timeout=180s
kubectl set image deployment/webapp nginx=nginx:1.25
kubectl rollout status deployment/webapp --timeout=180s
[ "$(kubectl get deployment webapp -o jsonpath='{.spec.template.spec.containers[0].image}')" = "nginx:1.25" ] || fail "update to 1.25 did not happen"
[ "$(kubectl get deployment webapp -o jsonpath='{.status.availableReplicas}')" = "3" ] || fail "not 3 available replicas after update"
kubectl rollout undo deployment/webapp
kubectl rollout status deployment/webapp --timeout=180s
[ "$(kubectl get deployment webapp -o jsonpath='{.spec.template.spec.containers[0].image}')" = "nginx:1.24" ] || fail "rollback to 1.24 did not happen"
kubectl rollout history deployment/webapp
kubectl delete -f 1.3-webapp-deployment.yaml --wait=true

step "1.4 ConfigMap and Secret"
# the value is a throw-away one; the real workflow creates the Secret by hand
kubectl create secret generic app-secret --from-literal=DB_PASSWORD="ci-$(date +%s)"
kubectl apply -f 1.4-config-secret.yaml
kubectl wait --for=condition=Ready pod/config-demo --timeout=180s
[ "$(kubectl exec config-demo -- printenv APP_ENV)" = "production" ] || fail "APP_ENV is not injected"
[ "$(kubectl exec config-demo -- printenv LOG_LEVEL)" = "info" ] || fail "LOG_LEVEL is not injected"
kubectl exec config-demo -- test -s /etc/secrets/DB_PASSWORD || fail "secret is not mounted at /etc/secrets"
if kubectl exec config-demo -- printenv DB_PASSWORD >/dev/null 2>&1; then fail "the Secret must be a volume, not an env var"; fi
kubectl delete -f 1.4-config-secret.yaml --wait=true
kubectl delete secret app-secret

step "1.5 Service types"
kubectl apply -f 1.5-services.yaml
kubectl rollout status deployment/httpd --timeout=180s
for s in httpd-clusterip httpd-nodeport httpd-loadbalancer; do
  kubectl get endpoints "$s" -o jsonpath='{.subsets[0].addresses[0].ip}' | grep -q . || fail "$s has no endpoints"
done
# ClusterIP: from inside the cluster, with a long-lived helper Pod (kubectl run --rm -i can lose a fast output)
kubectl run curl-test --image=busybox:1.36 --restart=Never -- sleep 300
kubectl wait --for=condition=Ready pod/curl-test --timeout=120s
clusterip_ok() { kubectl exec curl-test -- wget -qO- -T 5 http://httpd-clusterip | grep -q "It works"; }
retry 30 clusterip_ok || fail "ClusterIP does not answer"
kubectl delete pod curl-test --wait=true
# NodePort 30080: on a node (the kind node image has curl, not wget)
node=$(docker ps --format '{{.Names}}' | grep -m1 worker)
nodeport_ok() { docker exec "$node" curl -fsS -m 5 http://localhost:30080 | grep -q "It works"; }
retry 30 nodeport_ok || fail "NodePort 30080 does not answer on $node"
# LoadBalancer: kind has no cloud controller, the external address stays pending (expected)
[ "$(kubectl get svc httpd-loadbalancer -o jsonpath='{.spec.type}')" = "LoadBalancer" ] || fail "wrong type"
echo "LoadBalancer external address: '$(kubectl get svc httpd-loadbalancer -o jsonpath='{.status.loadBalancer.ingress[0].ip}')' (empty on kind, expected)"
kubectl delete -f 1.5-services.yaml --wait=true

step "1.6 Job and CronJob"
kubectl apply -f 1.6-job-cronjob.yaml
kubectl wait --for=condition=complete job/pi --timeout=100s
kubectl logs job/pi | head -c 40 | grep -q '^3.14159' || fail "pi is not printed"
[ "$(kubectl logs job/pi | tr -d '\n' | wc -c)" -ge 2000 ] || fail "less than 2000 digits"
[ "$(kubectl get cronjob print-date -o jsonpath='{.spec.schedule}')" = "*/5 * * * *" ] || fail "wrong schedule"
kubectl create job --from=cronjob/print-date print-date-manual
kubectl wait --for=condition=complete job/print-date-manual --timeout=120s
kubectl delete -f 1.6-job-cronjob.yaml --wait=true
kubectl delete job print-date-manual

step "1.7 DaemonSet"
nodes=$(kubectl get nodes --no-headers | wc -l)
kubectl apply -f 1.7-daemonset.yaml
kubectl rollout status daemonset/log-collector --timeout=240s
[ "$(kubectl get ds log-collector -o jsonpath='{.status.desiredNumberScheduled}')" = "$nodes" ] || fail "not one Pod per node (nodes: $nodes)"
[ "$(kubectl get ds log-collector -o jsonpath='{.status.numberReady}')" = "$nodes" ] || fail "not all DaemonSet Pods are ready"
kubectl get pods -l app=log-collector -o wide
kubectl delete -f 1.7-daemonset.yaml --wait=true

step "1.8 StatefulSet with a headless Service"
kubectl apply -f 1.8-statefulset.yaml
kubectl rollout status statefulset/redis-cluster --timeout=300s
kubectl wait --for=condition=Ready pod/busybox --timeout=180s
[ "$(kubectl get pvc -o name | grep -c 'data-redis-cluster-')" = "3" ] || fail "expected 3 PVCs"
[ "$(kubectl get pvc data-redis-cluster-0 -o jsonpath='{.status.phase}')" = "Bound" ] || fail "PVC is not bound"
[ "$(kubectl get pvc data-redis-cluster-0 -o jsonpath='{.spec.resources.requests.storage}')" = "1Gi" ] || fail "PVC is not 1Gi"
dns_ok() { kubectl exec busybox -- nslookup "redis-cluster-$1.redis-headless.default.svc.cluster.local" | grep -q "Address"; }
for i in 0 1 2; do
  retry 60 dns_ok "$i" || fail "DNS of redis-cluster-$i does not resolve"
done
kubectl exec busybox -- nslookup redis-cluster-0.redis-headless.default.svc.cluster.local
kubectl delete -f 1.8-statefulset.yaml --wait=true
kubectl delete pvc -l app=redis-cluster --wait=true

echo; echo "Section 1: all exercises passed"
