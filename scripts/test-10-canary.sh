#!/usr/bin/env bash
# Section 10.2: canary with ingress-nginx. Needs the cluster of scripts/setup-networking-cluster.sh (ingress on localhost:80).
set -euo pipefail
cd "$(dirname "$0")/../10-production-patterns"
source ../scripts/lib.sh

step "10.2 canary deployment with Ingress annotations"
retry 90 kubectl apply -f 10.2-canary.yaml        # the admission webhook of ingress-nginx may need a few seconds
for d in web-stable web-canary; do kubectl rollout status deployment/$d -n canary-demo --timeout=180s; done

# canary_share <n>: how many of n requests were answered by the canary
canary_share() {
  local n=$1 c=0 i out
  for i in $(seq "$n"); do
    out=$(curl -fsS -m 3 -H "Host: canary.local" http://localhost/ 2>/dev/null) || continue
    [ "$out" = "canary" ] && c=$((c+1))
  done
  echo "$c"
}
# in_range <weight> <min> <max> (of 200 requests); the statistics: 10% of 200 is 20 +- 4, 50% is 100 +- 7
in_range() {
  local c; c=$(canary_share 200)
  echo "canary-weight=$1: $c of 200 requests went to the canary (accepted: $2..$3)"
  [ "$c" -ge "$2" ] && [ "$c" -le "$3" ]
}
set_weight() {
  kubectl annotate ingress web-canary -n canary-demo "nginx.ingress.kubernetes.io/canary-weight=$1" --overwrite
}
retry 90 in_range 10 3 40   || fail "10%: the share of the canary is not around 10%"
set_weight 50
retry 90 in_range 50 60 140 || fail "50%: the share of the canary is not around 50%"
set_weight 100
retry 90 in_range 100 200 200 || fail "100%: not all requests went to the canary"
set_weight 0
retry 90 in_range 0 0 0     || fail "0%: some requests still went to the canary"
kubectl delete namespace canary-demo --wait=true

echo; echo "Section 10.2: passed"
