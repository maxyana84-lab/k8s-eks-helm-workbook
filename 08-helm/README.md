# 8. Helm

CI runs all the exercises on a kind cluster with `scripts/test-08.sh` (job `section-08`). The chart of exercises 8.2-8.7
is `myapp/`; each exercise uses a part of it.

| Exercise | Where |
|---|---|
| 8.1 A chart from a public repo | `8.1-bitnami-nginx-values.yaml` |
| 8.2 Your own chart | `myapp/` (`Chart.yaml`, `values.yaml`, `templates/`) |
| 8.3 Templating | `myapp/templates/_helpers.tpl`, `deployment.yaml`, `ingress.yaml` |
| 8.4 Upgrade and rollback | commands below |
| 8.5 Hooks | `myapp/templates/hooks.yaml` |
| 8.6 Subchart (PostgreSQL) | `myapp/Chart.yaml` (`dependencies`), `values.yaml` (`postgresql:`) |
| 8.7 Package and push to OCI | `8.7-publish.sh`, `../.github/workflows/publish-chart.yml` |

## 8.1 A chart from a public repo

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm search repo bitnami/nginx
helm install my-nginx bitnami/nginx --set replicaCount=3 --set service.type=NodePort -f 8.1-bitnami-nginx-values.yaml
helm list
helm status my-nginx
```

Bitnami stopped publishing versioned images under `docker.io/bitnami` (they moved to `bitnamilegacy`), so the values file points
the image there and sets `global.security.allowInsecureImages` (the chart refuses a different registry otherwise). Pin
`--version` of the chart in real use.

## 8.2 Your own chart

`helm create myapp` makes a scaffold with many files; this chart is written by hand with just what the exercise asks for:
a Deployment, a Service and a ConfigMap, with the image, the replicas and the environment variables in `values.yaml`.

```bash
helm lint myapp
helm template rel myapp                      # the dry-run: renders the manifests without a cluster
helm install myapp ./myapp --dry-run --debug # the dry-run against the cluster API
helm install myapp ./myapp
```

## 8.3 Templating

| Feature | Where | What it does |
|---|---|---|
| `{{ include }}` | `_helpers.tpl`: `myapp.fullname`, `myapp.labels`, `myapp.selectorLabels` | named templates; `include` (not `template`) returns a string, so it can be piped (`nindent`) |
| `{{- range }}` | `deployment.yaml`: `.Values.env` | one env var per key: `--set env.FOO=bar` adds one |
| `{{- if }}` | `ingress.yaml` | the Ingress exists only with `--set ingress.enabled=true` |
| `{{ toYaml }}` | `deployment.yaml` (`resources`), `configmap.yaml` (`config`) | copies a values subtree; `nindent` sets the indent |

Also: the annotation `checksum/config` (a hash of the ConfigMap) restarts the Pods when the ConfigMap changes: Helm does not do
it by itself. `{{-` and `-}}` trim the whitespace around an action: it matters because YAML has indentation.

## 8.4 Upgrade and rollback

The workbook says to change the image tag to 2.0; nginx has no such tag, so the test uses `1.26`.

```bash
helm install myapp ./myapp
helm upgrade myapp ./myapp --set image.tag=1.26     # revision 2
helm rollback myapp 1                               # revision 3, with the content of revision 1
helm history myapp
diff <(helm get manifest myapp --revision 1) <(helm get manifest myapp --revision 2)
```

A rollback does not go back in the history: it creates a **new revision** with the old content.

## 8.5 Hooks

- `migrate` is a Job with `helm.sh/hook: pre-install,pre-upgrade`: Helm runs it and waits until it succeeds **before** it creates the
  resources of the release (a failing migration stops the install). `hook-weight: "-5"` orders hooks of the same kind (the lower first).
- `notify` is a Job with `post-install`: it runs once, after the release is installed.
- `hook-delete-policy: before-hook-creation` (as the workbook asks): the Job of the previous run is deleted just before the new
  one is created, so the finished Job stays after the run and its log can be read: `kubectl logs job/myapp-migrate`. Without a
  policy the second upgrade fails because a Job with that name exists. `hook-succeeded` would delete it right after success.
- Hook resources are not part of the release: `helm uninstall` does not delete them.

CI checks that the migration finished before the Deployment was created, that the upgrade recreated the migration Job and that
the post-install Job did not run again.

## 8.6 Subchart (PostgreSQL)

`Chart.yaml` has the dependency `postgresql` (Bitnami, `16.x.x`) with `condition: postgresql.enabled`, so it is off unless asked for.
Everything under `postgresql:` in `values.yaml` goes to the subchart: database, user, persistence size. **The passwords are not in
`values.yaml`**: pass them when installing, or use `postgresql.auth.existingSecret`.

```bash
helm dependency update myapp          # downloads the subchart into myapp/charts/ (not committed)
helm install withdb ./myapp -n db --create-namespace \
  --set postgresql.enabled=true \
  --set postgresql.auth.password=<password> --set postgresql.auth.postgresPassword=<password>
```

The images come from `bitnamilegacy` for the reason given in 8.1.

## 8.7 Package and push to an OCI registry

`./8.7-publish.sh` packages the chart (`helm package`), pushes it (`helm push`), pulls it back (`helm pull`). With no arguments
it starts a local registry on `localhost:5000`, which is what CI does, then installs from it:

```bash
helm install myapp-oci oci://localhost:5000/charts/myapp --version 0.1.0 --plain-http
```

**GHCR** (the workflow `publish-chart.yml`, started by hand, or a tag `chart-v*`):

```bash
echo "$GITHUB_TOKEN" | helm registry login ghcr.io -u <user> --password-stdin
REGISTRY=oci://ghcr.io/<owner>/charts ./8.7-publish.sh
```

**ECR** (the hint of the workbook): the repository must exist and be named like the chart:

```bash
aws ecr create-repository --repository-name helm-charts/myapp
aws ecr get-login-password --region <region> | helm registry login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
REGISTRY=oci://<account>.dkr.ecr.<region>.amazonaws.com/helm-charts ./8.7-publish.sh
```

## What was verified

All exercises run on kind with assertions: the 8.1 chart with 3 replicas as a NodePort, the rendering rules of 8.3, the hooks and the
upgrade/rollback sequence of 8.4/8.5, the PostgreSQL subchart answering a query, and 8.7 against a local OCI registry. Not run: the push to GHCR
and to ECR (they need credentials), the login commands above.
