# 10. Production Patterns

| Exercise | Files | CI script |
|---|---|---|
| 10.1 Blue/Green | `10.1-bluegreen.yaml` | `test-10.sh` (plain kind) |
| 10.2 Canary with Ingress | `10.2-canary.yaml` | `test-10-canary.sh` (kind + Calico + ingress-nginx) |
| 10.3 Probes | `10.3-probes.yaml` | `test-10.sh` |
| 10.4 Prometheus + Grafana | `10.4-kps-values.yaml`, `10.4-app.yaml`, `10.4-servicemonitor.yaml` | `test-10-monitoring.sh` (kind, heavy) |

## 10.1 Blue/Green

Two full Deployments, `app-blue` (v1) and `app-green` (v2), both running; one Service chooses by the label `version`. The switch is one edit
of the selector: `kubectl patch svc myapp -p '{"spec":{"selector":{"app":"myapp","version":"green"}}}'`. Green is Ready before the
switch, so the endpoints change atomically from blue Pods to green Pods and no request meets a Pod that is not ready. CI sends 150 requests
during the switch and asserts **0 failed requests**, some answered by blue and some by green; the rollback is the same patch back. Cost: twice the
Pods during the switch; the old version can be scaled down after the check.

## 10.2 Canary with the nginx ingress controller

Two Ingresses for one host: `web-stable` (normal) and `web-canary` with `canary: "true"` and `canary-weight: "10"`. About 10% of the requests
go to the canary Service. The weight is changed with `kubectl annotate ... --overwrite` (10 -> 50 -> 100). CI measures 200 requests per step
and accepts a statistical range (the weight is a probability, not a counter): 10% -> 3..40, 50% -> 60..140, 100% -> all, 0% -> none. At 100% you
promote: make the stable Deployment run the new version and remove the canary Ingress. There is also `canary-by-header` for testers.

## 10.3 Probes

| Probe | Question | What happens on failure |
|---|---|---|
| startup | has the app started? (disables the other two until it succeeds) | container restarted after `failureThreshold` failures |
| liveness | is the app alive? | container restarted |
| readiness | can it take traffic? | removed from the Service endpoints, not restarted |

The app sleeps 20 s before it starts: with the startup probe (30 x 2 s = 60 s) it is not killed; without it the liveness probe would have
restarted the container in a loop. CI asserts that the Pod is Running but not Ready and has **0 restarts** during the start, and then removes
`index.html`: nginx answers 403, the HTTP liveness probe fails 3 times (10 s apart) and the container is restarted. Do not make the liveness probe
depend on external services (a database): their failure would restart every Pod at once.

## 10.4 Prometheus + Grafana

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kps prometheus-community/kube-prometheus-stack --version 75.15.1 -n monitoring --create-namespace \
  -f 10.4-kps-values.yaml --set grafana.adminPassword=<your password>
kubectl apply -f 10.4-app.yaml -f 10.4-servicemonitor.yaml
kubectl port-forward -n monitoring svc/kps-grafana 3000:80          # http://localhost:3000
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090
```

The `ServiceMonitor` tells the Prometheus Operator: scrape `/metrics` on the port `web` of the Services labelled `app=prom-example` every 15 s.
For it to be picked up, Prometheus must select ServiceMonitors that are not labelled with the Helm release: `serviceMonitorSelectorNilUsesHelmValues: false`
in the values file. **The default Grafana login of the workbook hint (`admin` / `prom-operator`) is a public default**: set your own password at install
time (it is not in Git); CI asserts that the default is rejected. Alertmanager and node-exporter are off to keep the stack small enough for kind.

CI checks: `sum(up{job="prom-example"}) == 2` (both Pods are scraped), the application's own metric `http_requests_total` is stored, the target's
`scrapeInterval` is `15s`, and Grafana answers with the password given and has a Prometheus data source.

## What was verified

All exercises run on kind with assertions (see the table). Not verified: nothing about EKS or real traffic; the percentages of 10.2 are statistical.
