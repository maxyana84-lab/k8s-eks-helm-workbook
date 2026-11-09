#!/usr/bin/env bash
# Runs the exercises of section 3. Needs a cluster prepared by scripts/setup-networking-cluster.sh.
set -euo pipefail
cd "$(dirname "$0")/../03-networking"
source ../scripts/lib.sh

step "3.1 NetworkPolicy"
kubectl apply -f 3.1-networkpolicy.yaml
kubectl rollout status deployment/api -n prod --timeout=180s
kubectl wait --for=condition=Ready pod/frontend-pod pod/other-pod -n prod --timeout=180s
reach() { kubectl exec -n prod "$1" -- wget -qO- -T 3 http://api-svc:8080 2>/dev/null | grep -q api-ok; }
# baseline: without policies everybody reaches the API
retry 60 reach other-pod || fail "baseline: other-pod cannot reach the API before the policies"
kubectl apply -f 3.1-policies.yaml
# frontend is allowed, other is denied (the policy needs a moment to be programmed)
retry 90 reach frontend-pod || fail "frontend-pod cannot reach api-svc:8080 after the policies"
denied() { if reach other-pod; then return 1; else return 0; fi; }
retry 90 denied || fail "other-pod can still reach the API: the deny-all policy is not enforced"
# the allowed port is 8080 only: a different port of the API Pod stays closed even for the frontend
api_ip=$(kubectl get pod -n prod -l role=api -o jsonpath='{.items[0].status.podIP}')
if kubectl exec -n prod frontend-pod -- wget -qO- -T 3 "http://$api_ip:9999" >/dev/null 2>&1; then fail "port 9999 must not be open"; fi
kubectl get networkpolicy -n prod
kubectl delete namespace prod --wait=true

step "3.2 Ingress with path-based routing"
# the admission webhook of ingress-nginx may need a few seconds after the controller is Ready
retry 90 kubectl apply -f 3.2-ingress.yaml
kubectl rollout status deployment/frontend -n ingress-demo --timeout=180s
kubectl rollout status deployment/api -n ingress-demo --timeout=180s
root_ok() { curl -fsS -m 5 http://localhost/ | grep -q "Welcome to nginx"; }
api_ok()  { curl -fsS -m 5 http://localhost/api | grep -q "api-via-ingress"; }
retry 90 root_ok || fail "/ is not routed to frontend-svc"
retry 90 api_ok  || fail "/api is not routed to api-svc"
kubectl get ingress -n ingress-demo
kubectl delete namespace ingress-demo --wait=true

step "3.3 DNS debugging"
kubectl apply -f 3.3-dns-debug.yaml
kubectl wait --for=condition=Ready pod/dns-debug --timeout=180s
# (1) a Service by its FQDN
svc_ip=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
kubectl exec dns-debug -- nslookup kubernetes.default.svc.cluster.local | tee /tmp/dns-svc.txt
grep -q "$svc_ip" /tmp/dns-svc.txt || fail "the FQDN of the kubernetes Service does not resolve to $svc_ip"
# (2) a Pod by its IP-based name: 10.244.1.5 -> 10-244-1-5.default.pod.cluster.local
pod_ip=$(kubectl get pod dns-debug -o jsonpath='{.status.podIP}')
pod_name="$(echo "$pod_ip" | tr . -).default.pod.cluster.local"
kubectl exec dns-debug -- nslookup "$pod_name" | tee /tmp/dns-pod.txt
grep -q "$pod_ip" /tmp/dns-pod.txt || fail "$pod_name does not resolve to $pod_ip"
# (3) /etc/resolv.conf
kubectl exec dns-debug -- cat /etc/resolv.conf | tee /tmp/resolv.txt
dns_ip=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
grep -q "^nameserver $dns_ip" /tmp/resolv.txt || fail "nameserver is not the kube-dns Service ($dns_ip)"
grep -q "^search default.svc.cluster.local svc.cluster.local cluster.local" /tmp/resolv.txt || fail "unexpected search domains"
grep -q "ndots:5" /tmp/resolv.txt || fail "ndots:5 is missing"
kubectl delete -f 3.3-dns-debug.yaml --wait=true

echo; echo "Section 3: all exercises passed"
