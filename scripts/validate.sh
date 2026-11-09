#!/usr/bin/env bash
# Validate every manifest of the workbook against the Kubernetes API schemas.
# Usage: scripts/validate.sh [dir ...]   (default: all NN-* folders)
set -euo pipefail
cd "$(dirname "$0")/.."
K8S_VERSION="${K8S_VERSION:-1.31.0}"
dirs=("$@")
if [ ${#dirs[@]} -eq 0 ]; then
  dirs=(0*-* 10-*)
fi
files=()
for d in "${dirs[@]}"; do
  [ -d "$d" ] || continue
  while IFS= read -r f; do files+=("$f"); done < <(find "$d" -type f \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/charts/*' -not -path '*/templates/*' -not -name '*values*.yaml' -not -name 'Chart.yaml' -not -name 'Chart.lock' | sort)
done
if [ ${#files[@]} -eq 0 ]; then echo "no manifests found"; exit 0; fi
kubeconform -strict -ignore-missing-schemas -kubernetes-version "$K8S_VERSION" -summary "${files[@]}"
