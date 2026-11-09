#!/usr/bin/env bash
# Exercise 7.3: IAM policy and the IRSA service account of the AWS Load Balancer Controller.
# Needs AWS credentials, eksctl and curl. Creates an IAM policy and a role: run it once per cluster.
set -euo pipefail
CLUSTER="${CLUSTER:-dev-cluster}"
REGION="${REGION:-eu-west-1}"
LBC_VERSION="${LBC_VERSION:-v2.13.4}"     # the controller release; its policy is published in its repository

curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json" \
  -o /tmp/aws-lb-controller-policy.json

POLICY_ARN=$(aws iam create-policy --policy-name "${CLUSTER}-AWSLoadBalancerControllerIAMPolicy" \
  --policy-document file:///tmp/aws-lb-controller-policy.json --query Policy.Arn --output text)

eksctl create iamserviceaccount --cluster "$CLUSTER" --region "$REGION" \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn "$POLICY_ARN" --approve

echo "Next: helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --version 1.13.4 \\"
echo "        -f 7.3-alb-controller-values.yaml --set vpcId=\$(aws eks describe-cluster --name $CLUSTER --region $REGION --query cluster.resourcesVpcConfig.vpcId --output text)"
