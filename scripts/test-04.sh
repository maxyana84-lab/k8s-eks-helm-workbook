#!/usr/bin/env bash
# Runs the exercises of section 4 that can run on kind (4.1, and the mechanism of 4.2).
# The EBS StorageClass of 4.2 and the EFS of 4.3 need AWS and are only validated by kubeconform.
set -euo pipefail
cd "$(dirname "$0")/../04-storage"
source ../scripts/lib.sh

step "4.1 PV and PVC (static provisioning)"
node=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
echo "the data lives on node $node"
kubectl label node "$node" workbook-storage=hostpath --overwrite
kubectl apply -f 4.1-pv-pvc.yaml
bound() { [ "$(kubectl get pvc data-pvc -o jsonpath='{.status.phase}')" = "Bound" ]; }
retry 60 bound || fail "the PVC data-pvc is not Bound"
[ "$(kubectl get pvc data-pvc -o jsonpath='{.spec.volumeName}')" = "data-pv" ] || fail "the PVC is bound to another PV"
kubectl apply -f 4.1-pod.yaml
kubectl wait --for=condition=Ready pod/data-pod --timeout=180s
[ "$(kubectl get pod data-pod -o jsonpath='{.spec.nodeName}')" = "$node" ] || fail "the Pod is not on the node of the PV"
kubectl delete pod data-pod --wait=true
kubectl apply -f 4.1-pod.yaml
kubectl wait --for=condition=Ready pod/data-pod --timeout=180s
lines=$(kubectl exec data-pod -- cat /data/log.txt | wc -l)
kubectl exec data-pod -- cat /data/log.txt
[ "$lines" = "2" ] || fail "expected 2 lines in /data/log.txt after the Pod was recreated, got $lines"
kubectl delete pod data-pod --wait=true
kubectl delete pvc data-pvc --wait=true
# Retain: the PV stays after its claim is deleted and is Released
[ "$(kubectl get pv data-pv -o jsonpath='{.status.phase}')" = "Released" ] || fail "the PV must be Released after the claim is deleted (Retain)"
kubectl delete pv data-pv --wait=true
docker exec "$node" rm -rf /mnt/data
kubectl label node "$node" workbook-storage-

step "4.2 dynamic provisioning (local-path stands in for EBS)"
kubectl apply -f 4.2-storageclass-kind.yaml
# WaitForFirstConsumer: nothing is provisioned until a Pod uses the claim
sleep 5
[ "$(kubectl get pvc fast-pvc-local -o jsonpath='{.status.phase}')" = "Pending" ] || fail "the PVC must wait for the first consumer"
[ "$(kubectl get pv --no-headers 2>/dev/null | wc -l)" = "0" ] || fail "no PV must exist before the Pod"
kubectl apply -f 4.2-pod-kind.yaml
kubectl wait --for=condition=Ready pod/fast-pod --timeout=180s
bound_local() { [ "$(kubectl get pvc fast-pvc-local -o jsonpath='{.status.phase}')" = "Bound" ]; }
retry 60 bound_local || fail "the PVC fast-pvc-local is not Bound"
pv=$(kubectl get pvc fast-pvc-local -o jsonpath='{.spec.volumeName}')
[ -n "$pv" ] || fail "no PV was created"
[ "$(kubectl get pv "$pv" -o jsonpath='{.spec.claimRef.name}')" = "fast-pvc-local" ] || fail "the created PV does not belong to the claim"
echo "PV created automatically: $pv"
kubectl delete -f 4.2-pod-kind.yaml -f 4.2-storageclass-kind.yaml --wait=true
gone() { [ "$(kubectl get pv --no-headers 2>/dev/null | wc -l)" = "0" ]; }
retry 60 gone || fail "reclaimPolicy Delete: the PV was not removed with its claim"

echo; echo "Section 4: all exercises that can run on kind passed (4.2 on EBS and 4.3 are validated only)"
