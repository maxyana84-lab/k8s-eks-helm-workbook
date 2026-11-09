#!/usr/bin/env bash
# Runs the exercises of section 2 on the current kubectl context and asserts the results.
set -euo pipefail
cd "$(dirname "$0")/../02-namespaces-resources"
source ../scripts/lib.sh

step "2.1 namespaces"
kubectl apply -f 2.1-namespaces.yaml
kubectl config set-context --current --namespace=dev
[ "$(kubectl config view --minify -o jsonpath='{..namespace}')" = "dev" ] || fail "the default namespace of the context is not dev"
for ns in dev staging prod; do
  kubectl apply -n "$ns" -f 2.1-nginx.yaml
done
for ns in dev staging prod; do
  kubectl rollout status deployment/nginx -n "$ns" --timeout=180s
done
# without -n the context namespace (dev) is used
[ "$(kubectl get pods --no-headers | grep -c '^nginx-')" = "1" ] || fail "kubectl get pods without -n must show only the dev Pod"
[ "$(kubectl get pods -A --no-headers | awk '$2 ~ /^nginx-/ {print $1}' | sort | tr '\n' ' ')" = "dev prod staging " ] || fail "nginx is not in each namespace"
kubectl get pods -A | grep -E 'NAMESPACE|nginx-'

step "2.2 ResourceQuota"
kubectl apply -f 2.2-resourcequota.yaml
kubectl describe resourcequota dev-quota -n dev
# 1) more Pods than the quota: 1 nginx exists, so only 4 of 8 replicas can be created
kubectl apply -n dev -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quota-test
spec:
  replicas: 8
  selector:
    matchLabels:
      app: quota-test
  template:
    metadata:
      labels:
        app: quota-test
    spec:
      containers:
        - name: sleep
          image: busybox:1.36
          command: ["sleep", "3600"]
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
EOF
pods_at_limit() { [ "$(kubectl get quota dev-quota -n dev -o jsonpath='{.status.used.pods}')" = "5" ]; }
retry 90 pods_at_limit || fail "the quota did not reach 5 Pods"
replica_failure() { [ "$(kubectl get rs -n dev -l app=quota-test -o jsonpath='{.items[0].status.conditions[?(@.type=="ReplicaFailure")].status}')" = "True" ]; }
retry 60 replica_failure || fail "the ReplicaSet does not report the quota error"
kubectl get rs -n dev -l app=quota-test -o jsonpath='{.items[0].status.conditions[?(@.type=="ReplicaFailure")].message}'; echo
[ "$(kubectl get pods -n dev --no-headers | wc -l)" -le 5 ] || fail "more than 5 Pods in dev"
kubectl delete deployment quota-test -n dev --wait=true
# 2) a Pod that asks for more CPU than the quota
out=$(kubectl apply -n dev -f - 2>&1 <<'EOF' || true
apiVersion: v1
kind: Pod
metadata:
  name: too-big
spec:
  containers:
    - name: sleep
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: "3"
          memory: 64Mi
EOF
)
echo "$out"
echo "$out" | grep -q "exceeded quota" || fail "the CPU request over the quota was not rejected"
# 3) the sixth Service
for i in 1 2 3 4 5; do kubectl create service clusterip "svc-$i" --tcp=80:80 -n dev; done
out=$(kubectl create service clusterip svc-6 --tcp=80:80 -n dev 2>&1 || true)
echo "$out"
echo "$out" | grep -q "exceeded quota" || fail "the sixth Service was not rejected"
for i in 1 2 3 4 5; do kubectl delete service "svc-$i" -n dev --ignore-not-found; done

step "2.3 LimitRange"
kubectl apply -f 2.3-limitrange.yaml
kubectl apply -f 2.3-pod-no-resources.yaml
get() { kubectl get pod no-resources -n dev -o jsonpath="$1"; }
[ "$(get '{.spec.containers[0].resources.requests.cpu}')" = "100m" ]    || fail "default CPU request not applied"
[ "$(get '{.spec.containers[0].resources.requests.memory}')" = "128Mi" ] || fail "default memory request not applied"
[ "$(get '{.spec.containers[0].resources.limits.cpu}')" = "500m" ]      || fail "default CPU limit not applied"
[ "$(get '{.spec.containers[0].resources.limits.memory}')" = "512Mi" ]  || fail "default memory limit not applied"
kubectl get pod no-resources -n dev -o jsonpath='{.spec.containers[0].resources}'; echo

step "cleanup"
kubectl config set-context --current --namespace=default
kubectl delete -f 2.1-namespaces.yaml --wait=true

echo; echo "Section 2: all exercises passed"
