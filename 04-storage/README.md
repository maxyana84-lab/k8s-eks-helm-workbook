# 4. Storage

| Exercise | Files | Verified |
|---|---|---|
| 4.1 PV and PVC (static provisioning) | `4.1-pv-pvc.yaml`, `4.1-pod.yaml` | kind (CI, `scripts/test-04.sh`) |
| 4.2 Dynamic provisioning with a StorageClass | `4.2-storageclass-ebs.yaml` (EKS), `4.2-storageclass-kind.yaml` (kind) | the mechanism on kind; the EBS file by kubeconform only |
| 4.3 EFS with ReadWriteMany | `4.3-efs.yaml` | kubeconform only, needs AWS |

## 4.1 Static provisioning

A PV is a piece of storage that an administrator creates; a PVC is a request that binds to a PV with a matching class,
size and access mode. `storageClassName: manual` is a name no StorageClass has, so the cluster's default StorageClass does
not provision a new volume for the claim.

The test deletes the Pod and creates it again: `/data/log.txt` has two lines (one per start), so the data survived the Pod.

Points worth knowing:

- `hostPath` is a directory on one node. The PV has a `nodeAffinity` so that the Pod always runs where the data is (CI labels
  a worker with `workbook-storage=hostpath`). hostPath is for single-node clusters and tests, not for production.
- `persistentVolumeReclaimPolicy: Retain`: after the PVC is deleted the PV stays in the state `Released` with its data, and an
  administrator decides what to do with it. `Delete` would remove the volume together with the claim.

## 4.2 Dynamic provisioning

On EKS (`4.2-storageclass-ebs.yaml`) the StorageClass `fast-storage` creates gp3 EBS volumes, encrypted, expandable.
`volumeBindingMode: WaitForFirstConsumer` waits for a Pod before creating the volume, so that it is created in the
availability zone of the node where the Pod is scheduled (an EBS volume lives in one zone).

**The workbook's `kubernetes.io/aws-ebs` provisioner no longer exists**: the in-tree driver was removed from Kubernetes (1.27).
Use the CSI driver `ebs.csi.aws.com` (exercise 7.4 installs it).

CI cannot use EBS, so `4.2-storageclass-kind.yaml` shows the same flow with kind's local-path provisioner and asserts it:
the PVC is `Pending` and no PV exists until the Pod starts; then a PV is created for the claim; deleting the claim removes
the PV (`reclaimPolicy: Delete`).

```bash
kubectl apply -f 4.2-storageclass-ebs.yaml     # on EKS
kubectl get pvc,pv                             # the PV appears after a Pod uses fast-pvc
```

## 4.3 EFS with ReadWriteMany

EBS volumes can be mounted by one node (ReadWriteOnce); EFS is NFS and can be mounted by many nodes, so three replicas on
different nodes write to one volume. Steps on EKS (not run here, they need an AWS account):

1. Install the EFS CSI driver (Helm chart `aws-efs-csi-driver`) with an IAM role for its service account (IRSA).
2. Create the EFS file system, and a mount target in each subnet of the nodes; the security group of the mount targets
   allows TCP 2049 from the nodes.
3. Put the file system ID into the StorageClass (`fileSystemId`, a placeholder `fs-REPLACE_ME` in the file), then:

```bash
kubectl apply -f 4.3-efs.yaml
kubectl exec deploy/efs-writers -- cat /data/shared.log     # lines from all three Pods
```

EFS is billed by the data it stores, and mount targets are free. Delete the file system when done.
