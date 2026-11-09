#!/usr/bin/env bash
# Section 10.4: kube-prometheus-stack with a custom ServiceMonitor. Needs helm and jq. Heavy: about 5-8 minutes.
set -euo pipefail
cd "$(dirname "$0")/../10-production-patterns"
source ../scripts/lib.sh

step "10.4 kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
pw=$(openssl rand -hex 12)
helm install kps prometheus-community/kube-prometheus-stack --version 75.15.1 -n monitoring --create-namespace \
  -f 10.4-kps-values.yaml --set grafana.adminPassword="$pw" --wait --timeout 12m
kubectl get pods -n monitoring

step "10.4 the application and its ServiceMonitor"
kubectl apply -f 10.4-app.yaml
kubectl rollout status deployment/prom-example --timeout=180s
kubectl apply -f 10.4-servicemonitor.yaml

kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 19090:9090 >/tmp/pf-prom.log 2>&1 &
pf_prom=$!
kubectl port-forward -n monitoring svc/kps-grafana 13000:80 >/tmp/pf-grafana.log 2>&1 &
pf_graf=$!
trap 'kill $pf_prom $pf_graf 2>/dev/null || true' EXIT

query() { curl -fsS -m 10 --get http://localhost:19090/api/v1/query --data-urlencode "query=$1"; }
up_two() { [ "$(query 'sum(up{job="prom-example"})' | jq -r '.data.result[0].value[1] // "0"')" = "2" ]; }
retry 240 up_two || { query 'up{job="prom-example"}' || true; fail "Prometheus does not scrape the 2 Pods of the application (up != 2)"; }
echo "the 2 Pods of prom-example are scraped: up = 2"
# the application's own metric: the counter http_requests_total has no series until the first requests, so send some
kubectl run traffic --image=busybox:1.36 --restart=Never -- \
  sh -c 'i=0; while [ $i -lt 20 ]; do wget -qO /dev/null http://prom-example:8080/; i=$((i+1)); sleep 1; done'
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/traffic --timeout=120s
kubectl delete pod traffic --wait=true
has_metric() { [ "$(query 'sum(http_requests_total{job="prom-example"})' | jq -r '.data.result | length')" = "1" ]; }
retry 90 has_metric || fail "the application metric http_requests_total is not in Prometheus"
# 15 s interval
interval=$(curl -fsS -m 10 http://localhost:19090/api/v1/targets | jq -r '[.data.activeTargets[] | select(.labels.job=="prom-example") | .scrapeInterval] | unique | join(",")')
echo "scrape interval of the job prom-example: $interval"
[ "$interval" = "15s" ] || fail "the scrape interval is '$interval', not 15s"

step "10.4 Grafana"
graf_ok() { curl -fsS -m 5 -u "admin:$pw" http://localhost:13000/api/datasources | jq -e '.[] | select(.type=="prometheus")' >/dev/null; }
retry 120 graf_ok || fail "Grafana does not answer with the admin password given at install time (or has no Prometheus datasource)"
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -u admin:prom-operator http://localhost:13000/api/datasources || true)
[ "$code" = "401" ] || fail "the default password admin/prom-operator must not work (got HTTP $code)"
echo "Grafana answers to our password (datasource: Prometheus) and rejects the well-known default"

echo; echo "Section 10.4: passed"
