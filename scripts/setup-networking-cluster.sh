#!/usr/bin/env bash
# Installs Calico and ingress-nginx into a kind cluster created with scripts/kind-config-networking.yaml.
set -euo pipefail
CALICO_VERSION="${CALICO_VERSION:-v3.28.2}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.11.2}"

kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl rollout status daemonset/calico-node -n kube-system --timeout=300s

kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
kubectl wait --namespace ingress-nginx --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=300s
