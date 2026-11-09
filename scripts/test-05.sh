#!/usr/bin/env bash
# Runs the exercises of section 5 and asserts the results.
set -euo pipefail
cd "$(dirname "$0")/../05-rbac-security"
source ../scripts/lib.sh

can() { kubectl auth can-i "$@" 2>/dev/null; }   # prints yes or no; exit code 1 on "no"
expect() { local want=$1; shift; local got; got=$(can "$@" || true); [ "$got" = "$want" ] || fail "can-i $* -> '$got', expected '$want'"; }

step "5.1 ServiceAccount + Role + RoleBinding"
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f 5.1-rbac-dev.yaml
sa=system:serviceaccount:dev:deploy-bot
expect yes list pods --as="$sa" -n dev
expect yes get pods --as="$sa" -n dev
expect yes watch pods --as="$sa" -n dev
expect yes list deployments.apps --as="$sa" -n dev
expect no  delete pods --as="$sa" -n dev
expect no  create deployments.apps --as="$sa" -n dev
expect no  list secrets --as="$sa" -n dev
expect no  list pods --as="$sa" -n default       # a Role is limited to its namespace
kubectl auth can-i --list --as="$sa" -n dev | head -20

step "5.2 ClusterRole for node access"
kubectl apply -f 5.2-clusterrole-nodes.yaml
expect yes list nodes --as=alice --as-group=ops-team
expect yes get persistentvolumes --as=alice --as-group=ops-team
expect no  delete nodes --as=alice --as-group=ops-team
expect no  list nodes --as=alice                  # without the group there is no access
expect no  list pods -n default --as=alice --as-group=ops-team

step "5.3 Pod Security Admission"
kubectl apply -f 5.3-namespace-restricted.yaml
out=$(kubectl apply -f 5.3-privileged-pod.yaml 2>&1 || true)
echo "$out"
echo "$out" | grep -q 'violates PodSecurity "restricted:latest"' || fail "the privileged Pod was not rejected by the restricted standard"
[ "$(kubectl get pod privileged-pod -n prod --no-headers 2>/dev/null | wc -l)" = "0" ] || fail "the privileged Pod exists"
kubectl apply -f 5.3-compliant-pod.yaml
kubectl wait --for=condition=Ready pod/compliant-pod -n prod --timeout=180s

step "cleanup"
kubectl delete -f 5.3-compliant-pod.yaml --ignore-not-found
kubectl delete namespace prod dev --wait=true
kubectl delete -f 5.2-clusterrole-nodes.yaml

echo; echo "Section 5: all exercises passed"
