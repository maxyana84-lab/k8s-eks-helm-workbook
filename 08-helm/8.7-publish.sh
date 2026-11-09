#!/usr/bin/env bash
# Exercise 8.7: package the chart and push it to an OCI registry, then pull it back and install from it.
#   REGISTRY=oci://ghcr.io/<owner>/charts ./8.7-publish.sh                                 # GHCR (login first, see README)
#   REGISTRY=oci://<account>.dkr.ecr.<region>.amazonaws.com/helm-charts ./8.7-publish.sh   # ECR (the repository helm-charts/myapp must exist)
# Without REGISTRY a local registry on localhost:5000 is started (what CI does).
set -euo pipefail
cd "$(dirname "$0")"
EXTRA=()
if [ -z "${REGISTRY:-}" ]; then
  REGISTRY="oci://localhost:5000/charts"
  EXTRA=(--plain-http)
  docker rm -f workbook-registry >/dev/null 2>&1 || true
  docker run -d --name workbook-registry -p 5000:5000 registry:2 >/dev/null
  until curl -fsS http://localhost:5000/v2/ >/dev/null; do sleep 1; done
fi

helm dependency update myapp >/dev/null
OUT=$(mktemp -d)
helm package myapp --destination "$OUT"
PKG=$(ls "$OUT"/myapp-*.tgz)
helm push "$PKG" "$REGISTRY" "${EXTRA[@]}"
VERSION=$(basename "$PKG" .tgz | sed 's/^myapp-//')

helm pull "$REGISTRY/myapp" --version "$VERSION" --destination "$OUT/pulled" --untar "${EXTRA[@]}"
test -f "$OUT/pulled/myapp/Chart.yaml"
echo "pushed and pulled $REGISTRY/myapp:$VERSION"
echo "install from the registry: helm install myapp-oci $REGISTRY/myapp --version $VERSION ${EXTRA[*]}"
