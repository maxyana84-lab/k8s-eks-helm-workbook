# 7. Amazon EKS

These exercises need a real AWS account and **cost money**. Nothing here was run against AWS: CI validates the files
(see "What was verified"). Run the exercises yourself in this order, and delete everything at the end.

| Exercise | Files |
|---|---|
| 7.1 Cluster with eksctl | `7.1-cluster.yaml` |
| 7.2 IRSA | `7.2-irsa.yaml`, `7.2-pod.yaml` |
| 7.3 AWS Load Balancer Controller + Ingress | `7.3-create-alb-iam.sh`, `7.3-alb-controller-values.yaml`, `7.3-ingress.yaml` |
| 7.4 EBS CSI driver + gp3 | `7.4-ebs-statefulset.yaml` (the add-on is in `7.1-cluster.yaml`) |
| 7.5 Cluster Autoscaler | `7.5-cluster-autoscaler-values.yaml`, `7.5-stress.yaml`, `iam/cluster-autoscaler-policy.json` |
| 7.6 Fargate profile | `7.6-fargate.yaml`, `7.6-workload.yaml` |

What costs money while the cluster exists: the EKS control plane (about $0.10 per hour), the nodes (2 x t3.medium), a NAT
gateway that eksctl creates for the cluster VPC (billed per hour and per GB), every ALB, every EBS volume, and Fargate Pods
(billed for their CPU and memory). Check the current prices for your region, and delete the cluster when you finish the same day.

## 7.1 Cluster with eksctl

```bash
eksctl create cluster -f 7.1-cluster.yaml
aws eks update-kubeconfig --name dev-cluster --region eu-west-1
kubectl get nodes          # 2 nodes Ready
```

eksctl creates a VPC, the control plane and the managed node group through CloudFormation. The file already has what the
later exercises need: `iam.withOIDC` (7.2), the `aws-ebs-csi-driver` add-on with its IAM role (7.4), and the autoscaler tags
on the node group (7.5). `kubectl` here would point at *this* cluster: check `kubectl config current-context` before you apply
anything if you have other clusters in your kubeconfig.

## 7.2 IRSA (IAM Roles for Service Accounts)

The OIDC provider lets IAM trust tokens issued by the cluster. The role's trust policy says: "a token of the service account
`default/s3-reader` of this cluster may assume this role", so only Pods using that account get the S3 permissions, without access
keys. Kubernetes projects a token into the Pod, and the AWS SDK exchanges it (`AssumeRoleWithWebIdentity`).

```bash
eksctl create iamserviceaccount -f 7.2-irsa.yaml --approve
kubectl get sa s3-reader -o yaml | grep role-arn     # the annotation from the hint of the workbook
kubectl apply -f 7.2-pod.yaml
kubectl logs s3-lister                                # the list of your S3 buckets
kubectl exec ... env | grep AWS_ROLE_ARN              # injected by the EKS pod identity webhook
```

## 7.3 AWS Load Balancer Controller and an ALB Ingress

```bash
./7.3-create-alb-iam.sh                  # IAM policy + service account (needs the cluster of 7.1)
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --version 1.13.4 -f 7.3-alb-controller-values.yaml --set vpcId=<vpc id>
kubectl apply -f 7.3-ingress.yaml
kubectl get ingress echo                 # ADDRESS = the DNS name of the ALB
curl http://<ADDRESS>/                   # hello from the ALB
```

Annotations: `scheme: internet-facing` puts the ALB in the public subnets; `target-type: ip` registers the Pod IPs as targets
(`instance` would use node ports). The subnets need the tags `kubernetes.io/role/elb=1` (public) and
`kubernetes.io/role/internal-elb=1` (private); eksctl sets them. **Delete the Ingress before the cluster**, otherwise the ALB
stays and is billed.

## 7.4 EBS CSI driver and gp3

The add-on is installed by `7.1-cluster.yaml` (the IAM role is `wellKnownPolicies.ebsCSIController`). Without the driver a PVC
with `ebs.csi.aws.com` stays `Pending`. `volumeBindingMode: WaitForFirstConsumer` creates the volume in the zone of the node
chosen for the Pod (EBS volumes live in one zone).

```bash
kubectl apply -f 7.4-ebs-statefulset.yaml
kubectl get pvc,pv                       # a 5Gi gp3 volume per replica
```

`reclaimPolicy: Delete`: deleting the claim deletes the volume. Delete the PVCs (`kubectl delete pvc -l app=ebs-demo`).

## 7.5 Cluster Autoscaler

It adds nodes when Pods are Pending for lack of resources, and removes nodes that are mostly idle. It finds node groups by the
two tags `k8s.io/cluster-autoscaler/enabled` and `k8s.io/cluster-autoscaler/dev-cluster`. The policy in `iam/` lets it change
only the groups that carry both. This is the same exercise as the one in the `helm-kubernetes-demo` repository
(`exercise-4-cluster-autoscaler`, with answers to its questions).

```bash
aws iam create-policy --policy-name dev-cluster-cluster-autoscaler --policy-document file://iam/cluster-autoscaler-policy.json
eksctl create iamserviceaccount --cluster dev-cluster --region eu-west-1 --namespace kube-system \
  --name cluster-autoscaler --attach-policy-arn <arn of that policy> --approve
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler -n kube-system -f 7.5-cluster-autoscaler-values.yaml
kubectl apply -f 7.5-stress.yaml && kubectl get pods -w     # some Pods Pending, then a new node appears
```

The node group allows up to 4 nodes (`maxSize: 4`); 8 replicas with a request of 500m do not fit on 2 t3.medium nodes. The
autoscaler image minor version should match the cluster's Kubernetes minor version.

## 7.6 Fargate profile

```bash
eksctl create fargateprofile -f 7.6-fargate.yaml
kubectl create namespace serverless
kubectl apply -f 7.6-workload.yaml
kubectl get nodes -L eks.amazonaws.com/compute-type      # nodes fargate-ip-..., one per Pod
```

A Pod is run on Fargate when its namespace (and labels, if the profile has them) match a profile; the Pod then gets its own
micro-VM and node. The VM is sized from the Pod's requests, so they are mandatory in practice. Fargate does not run DaemonSets,
privileged Pods, or use EBS volumes. A Pod created **before** the profile stays on the normal nodes.

## Clean-up (in this order)

```bash
kubectl delete -f 7.6-workload.yaml -f 7.5-stress.yaml -f 7.4-ebs-statefulset.yaml -f 7.3-ingress.yaml
kubectl delete pvc --all                                  # the EBS volumes
helm uninstall cluster-autoscaler aws-load-balancer-controller -n kube-system
eksctl delete fargateprofile --cluster dev-cluster --region eu-west-1 --name fp-serverless
eksctl delete cluster -f 7.1-cluster.yaml --wait          # control plane, nodes, VPC, NAT gateway
```

Also delete the IAM policies you created, and check in the console that no load balancers, volumes or NAT gateways are left.

## What was verified

- CI: the Kubernetes manifests with `kubeconform`; every `ClusterConfig` against the JSON schema of eksctl itself
  (`eksctl utils schema`, job `eks-configs`); the IAM policy as JSON; the shell script with `bash -n`.
- **Not run**: nothing was created in AWS. In particular the image tag `amazon/aws-cli:2.17.40` of 7.2, the commands above and
  the behaviour of the ALB, EBS, Fargate and the autoscaler are not tested here.
