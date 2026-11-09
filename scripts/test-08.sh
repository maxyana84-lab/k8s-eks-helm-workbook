#!/usr/bin/env bash
# Runs the exercises of section 8 on the current kubectl context (kind) and asserts the results.
# Needs: helm 3.13+ (for --plain-http), jq, docker (a local OCI registry for 8.7).
set -euo pipefail
cd "$(dirname "$0")/../08-helm"
source ../scripts/lib.sh

helm version --short

step "8.1 a chart from a public repo (bitnami/nginx)"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo bitnami/nginx
helm install my-nginx bitnami/nginx -f 8.1-bitnami-nginx-values.yaml \
  --set replicaCount=3 --set service.type=NodePort --wait --timeout 5m
helm list
[ "$(helm status my-nginx -o json | jq -r .info.status)" = "deployed" ] || fail "my-nginx is not deployed"
[ "$(kubectl get deployment my-nginx -o jsonpath='{.status.readyReplicas}')" = "3" ] || fail "my-nginx does not have 3 ready replicas"
[ "$(kubectl get svc my-nginx -o jsonpath='{.spec.type}')" = "NodePort" ] || fail "the Service is not a NodePort"
helm uninstall my-nginx

step "8.2/8.3 the chart myapp: lint, template, dry-run"
helm dependency update myapp
helm lint myapp
default=$(helm template rel myapp)
grep -q '^kind: ConfigMap' <<<"$default"        || fail "no ConfigMap"
grep -q '^kind: Deployment' <<<"$default"       || fail "no Deployment"
grep -q '^kind: Service' <<<"$default"          || fail "no Service"
grep -q 'replicas: 2' <<<"$default"             || fail "replicas are not taken from values"
grep -q 'image: "nginx:1.25"' <<<"$default"     || fail "image is not taken from values"
# (2) range: one env var per key of .Values.env
grep -q 'name: APP_ENV' <<<"$default"           || fail "range: APP_ENV is missing"
grep -q 'name: LOG_LEVEL' <<<"$default"         || fail "range: LOG_LEVEL is missing"
withenv=$(helm template rel myapp --set env.FOO=bar)
grep -q 'name: FOO' <<<"$withenv"               || fail "range: a new key of values does not become an env var"
# (3) if: the Ingress only when enabled
if grep -q '^kind: Ingress' <<<"$default"; then fail "the Ingress must not exist by default"; fi
withing=$(helm template rel myapp --set ingress.enabled=true --set ingress.host=app.example.com)
grep -q '^kind: Ingress' <<<"$withing"          || fail "if: the Ingress is missing when enabled"
grep -q 'app.example.com' <<<"$withing"         || fail "the Ingress host is not taken from values"
# (1) include: the labels come from a named template
grep -q 'app.kubernetes.io/name: myapp' <<<"$default" || fail "include: labels are missing"
# (4) toYaml: resources are copied as they are
grep -q 'cpu: 200m' <<<"$default"               || fail "toYaml: the resource limits are missing"
helm template rel myapp --set ingress.enabled=true | kubectl apply --dry-run=server -f -

step "8.5 install with hooks"
helm install myapp ./myapp --wait --timeout 5m
for j in myapp-migrate myapp-notify; do
  [ "$(kubectl get job "$j" -o jsonpath='{.status.succeeded}')" = "1" ] || fail "the hook Job $j did not succeed"
done
kubectl logs job/myapp-migrate
# pre-install: the migration finished BEFORE the Deployment was created
mig_done=$(kubectl get job myapp-migrate -o jsonpath='{.status.completionTime}')
dep_created=$(kubectl get deployment myapp -o jsonpath='{.metadata.creationTimestamp}')
[[ "$mig_done" < "$dep_created" || "$mig_done" == "$dep_created" ]] || fail "the migration ($mig_done) finished after the Deployment was created ($dep_created)"
[ "$(kubectl get job myapp-migrate -o jsonpath='{.metadata.annotations.helm\.sh/hook-delete-policy}')" = "before-hook-creation" ] || fail "hook-delete-policy is not before-hook-creation"
migrate_uid=$(kubectl get job myapp-migrate -o jsonpath='{.metadata.uid}')
notify_uid=$(kubectl get job myapp-notify -o jsonpath='{.metadata.uid}')

step "8.4 upgrade and rollback"
helm upgrade myapp ./myapp --set image.tag=1.26 --wait --timeout 5m
[ "$(kubectl get deployment myapp -o jsonpath='{.spec.template.spec.containers[0].image}')" = "nginx:1.26" ] || fail "the upgrade did not change the image"
[ "$(helm history myapp -o json | jq length)" = "2" ] || fail "expected 2 revisions after the upgrade"
# pre-upgrade hook ran again (before-hook-creation recreated the Job); post-install did not
[ "$(kubectl get job myapp-migrate -o jsonpath='{.metadata.uid}')" != "$migrate_uid" ] || fail "the migration Job was not recreated by the upgrade"
[ "$(kubectl get job myapp-notify -o jsonpath='{.metadata.uid}')" = "$notify_uid" ] || fail "the post-install Job must not run on upgrade"
helm rollback myapp 1 --wait --timeout 5m
[ "$(kubectl get deployment myapp -o jsonpath='{.spec.template.spec.containers[0].image}')" = "nginx:1.25" ] || fail "the rollback did not restore the image"
[ "$(helm history myapp -o json | jq length)" = "3" ] || fail "a rollback is a new revision: expected 3"
helm history myapp
diff_out=$(diff <(helm get manifest myapp --revision 1) <(helm get manifest myapp --revision 2) || true)
echo "$diff_out"
grep -q 'nginx:1.26' <<<"$diff_out" || fail "the comparison of revisions 1 and 2 does not show the new image"
helm uninstall myapp
kubectl delete job myapp-migrate myapp-notify --ignore-not-found

step "8.6 PostgreSQL subchart"
pw=$(openssl rand -hex 12)
helm install withdb ./myapp -n db --create-namespace --set hooks.enabled=false \
  --set postgresql.enabled=true --set postgresql.auth.password="$pw" --set postgresql.auth.postgresPassword="$pw" \
  --wait --timeout 10m
kubectl rollout status statefulset/myapp-postgresql -n db --timeout=300s
[ "$(kubectl get pvc -n db -o jsonpath='{.items[0].spec.resources.requests.storage}')" = "1Gi" ] || fail "persistence size is not taken from values"
# the Pod can be Ready while the init server of the Bitnami image is still being replaced by the real one: retry
db_query() { got=$(kubectl exec -n db myapp-postgresql-0 -- env PGPASSWORD="$pw" psql -h 127.0.0.1 -U app -d appdb -tAc 'select 1' 2>/dev/null) && [ "$got" = "1" ]; }
retry 120 db_query || fail "cannot query the database with the user and the database of values (got '${got:-}')"
helm uninstall withdb -n db
kubectl delete namespace db --wait=true

step "8.7 package and push to an OCI registry"
./8.7-publish.sh
version=$(awk '/^version:/ {print $2}' myapp/Chart.yaml)
helm install fromoci oci://localhost:5000/charts/myapp --version "$version" --plain-http --set hooks.enabled=false --wait --timeout 5m
kubectl get deployment fromoci-myapp
[ "$(helm list -o json | jq -r '.[] | select(.name=="fromoci") | .chart')" = "myapp-$version" ] || fail "the release does not use the chart from the registry"
helm uninstall fromoci
docker rm -f workbook-registry >/dev/null

echo; echo "Section 8: all exercises passed"
