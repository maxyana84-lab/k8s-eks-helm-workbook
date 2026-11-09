#!/usr/bin/env bash
# Runs the exercises of section 6. Needs a cluster with 2 worker nodes (scripts/kind-config.yaml).
set -euo pipefail
cd "$(dirname "$0")/../06-scheduling-scaling"
source ../scripts/lib.sh

mapfile -t workers < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[ "${#workers[@]}" -ge 2 ] || fail "two worker nodes are needed"
w1=${workers[0]}; w2=${workers[1]}
echo "workers: $w1 $w2"

step "6.1 node affinity and pod anti-affinity"
kubectl label node "$w2" disk=ssd --overwrite
kubectl apply -f 6.1-ssd-pod.yaml
kubectl wait --for=condition=Ready pod/ssd-pod --timeout=180s
[ "$(kubectl get pod ssd-pod -o jsonpath='{.spec.nodeName}')" = "$w2" ] || fail "ssd-pod is not on the node labelled disk=ssd"
kubectl apply -f 6.1-spread-deployment.yaml
kubectl rollout status deployment/spread --timeout=180s
nodes_used=$(kubectl get pods -l app=spread -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)
[ "$nodes_used" = "2" ] || fail "the two replicas share a node"
kubectl get pods -l app=spread -o wide
kubectl delete -f 6.1-ssd-pod.yaml -f 6.1-spread-deployment.yaml --wait=true
kubectl label node "$w2" disk-

step "6.2 taints and tolerations"
kubectl label node "$w2" env=prod --overwrite
kubectl taint node "$w2" env=prod:NoSchedule
kubectl apply -f 6.2-no-toleration.yaml
kubectl rollout status deployment/no-toleration --timeout=180s
on_tainted=$(kubectl get pods -l app=no-toleration -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | grep -c "^$w2$" || true)
[ "$on_tainted" = "0" ] || fail "$on_tainted Pods without a toleration landed on the tainted node"
kubectl apply -f 6.2-toleration-pod.yaml
kubectl wait --for=condition=Ready pod/tolerating-pod --timeout=180s
[ "$(kubectl get pod tolerating-pod -o jsonpath='{.spec.nodeName}')" = "$w2" ] || fail "the tolerating Pod is not on the tainted node"
kubectl delete -f 6.2-no-toleration.yaml -f 6.2-toleration-pod.yaml --wait=true
kubectl taint node "$w2" env=prod:NoSchedule-
kubectl label node "$w2" env-

step "6.3 HPA with metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
# kind kubelets have self-signed certificates
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=180s
retry 180 kubectl top nodes || fail "metrics-server does not return metrics"
kubectl apply -f 6.3-hpa.yaml
kubectl rollout status deployment/php-apache --timeout=180s
kubectl apply -f 6.3-load.yaml
scaled_up() { [ "$(kubectl get deployment php-apache -o jsonpath='{.status.replicas}')" -gt 2 ]; }
retry 420 scaled_up || { kubectl describe hpa php-apache; fail "the HPA did not scale php-apache above 2 replicas"; }
kubectl get hpa php-apache
kubectl delete -f 6.3-load.yaml -f 6.3-hpa.yaml --wait=true

step "6.4 PodDisruptionBudget and drain"
kubectl apply -f 6.4-pdb.yaml
kubectl rollout status deployment/webapp --timeout=180s
allowed() { [ "$(kubectl get pdb webapp-pdb -o jsonpath='{.status.disruptionsAllowed}')" = "$1" ]; }
retry 60 allowed 1 || fail "with 3 replicas and minAvailable=2 exactly 1 disruption must be allowed"
kubectl get pdb webapp-pdb
node=$(kubectl get pod -l app=webapp -o jsonpath='{.items[0].spec.nodeName}')
# (a) minAvailable=3 means no Pod may be evicted: the drain is blocked
kubectl patch pdb webapp-pdb --type merge -p '{"spec":{"minAvailable":3}}'
retry 60 allowed 0 || fail "minAvailable=3 must allow 0 disruptions"
out=$(kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=30s 2>&1 || true)
echo "$out" | tail -5
echo "$out" | grep -q "violate the pod's disruption budget" || fail "the drain was not blocked by the budget"
kubectl uncordon "$node"
# (b) the budget of the workbook (minAvailable=2): the drain goes through, one Pod at a time
kubectl patch pdb webapp-pdb --type merge -p '{"spec":{"minAvailable":2}}'
retry 60 allowed 1 || fail "minAvailable=2 must allow 1 disruption"
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=240s
kubectl rollout status deployment/webapp --timeout=180s
[ "$(kubectl get pods -l app=webapp --field-selector spec.nodeName="$node" --no-headers | wc -l)" = "0" ] || fail "Pods are still on the drained node"
kubectl uncordon "$node"
kubectl delete -f 6.4-pdb.yaml --wait=true

echo; echo "Section 6: all exercises passed"
