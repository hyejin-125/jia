#!/bin/bash
set -x

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-west-2"
CLUSTER_NAME="skills-sqs-cluster"
KARPENTER_NS="karpenter"
KARPENTER_VERSION="1.3.3"
KARPENTER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/skills-karpenter-controller-role"

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh
helm repo add eks https://aws.github.io/eks-charts
helm repo update
rm -f get_helm.sh
helm repo add karpenter https://charts.karpenter.sh/ 2>/dev/null || true
helm repo update

# Get cluster endpoint
CLUSTER_ENDPOINT=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --query "cluster.endpoint" \
  --output text)

# Install Karpenter
helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NS}" \
  --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_ROLE_ARN}" \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=256Mi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set replicas=1 \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists \
  --set tolerations[0].effect=NoSchedule \
  --set nodeSelector."kubernetes\.io/os"=linux \
  --wait

kubectl get pod -n $KARPENTER_NS -l app.kubernetes.io/name=karpenter

kubectl create ns skills-sqs --dry-run=client -o yaml | kubectl apply -f -
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --namespace=skills-sqs \
  --name=sqs-worker-sa \
  --attach-policy-arn=arn:aws:iam::aws:policy/AmazonSQSFullAccess \
  --approve

sleep  10
echo