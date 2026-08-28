#!/bin/bash
set -x

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-west-2"
CLUSTER_NAME="skills-sqs-cluster"
APP_NS="skills-sqs"
KEDA_NS="keda"
KEDA_VERSION="2.16.1"

VPC_ID=$(aws ec2 describe-vpcs --region $REGION \
  --filters "Name=tag:Name,Values=*skills-sqs-vpc*" \
  --query "Vpcs[0].VpcId" --output text)

PRIV_A=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=${REGION}a" "Name=tag:Name,Values=*priv*,*Priv*,*Private*,*private*" \
  --query "Subnets[0].SubnetId" --output text)

PRIV_B=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=${REGION}b" "Name=tag:Name,Values=*priv*,*Priv*,*Private*,*private*" \
  --query "Subnets[0].SubnetId" --output text)

CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

kubectl create namespace $KEDA_NS --dry-run=client -o yaml | kubectl apply -f -

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --namespace=$KEDA_NS \
  --name=keda-operator \
  --attach-policy-arn=arn:aws:iam::aws:policy/AmazonSQSReadOnlyAccess \
  --override-existing-serviceaccounts \
  --approve

kubectl create namespace $APP_NS --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF > ./keda-and-karpenter.yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: sqs-worker-trigger-auth
  namespace: ${APP_NS}
spec:
  podIdentity:
    provider: aws-eks
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: sqs-worker-scaledobject
  namespace: ${APP_NS}
spec:
  scaleTargetRef:
    name: sqs-worker
  minReplicaCount: 0
  maxReplicaCount: 6
  pollingInterval: 15
  cooldownPeriod: 30
  triggers:
    - type: aws-sqs-queue
      authenticationRef:
        name: sqs-worker-trigger-auth
      metadata:
        queueURL: https://sqs.${REGION}.amazonaws.com/${ACCOUNT_ID}/skills-sqs-queue
        queueLength: "2"
        awsRegion: ${REGION}
        identityOwner: operator
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: skills-sqs-nodepool
spec:
  template:
    metadata:
      labels:
        skills-nodepool: event-worker
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.small", "t3.medium"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: skills-sqs-nodeclass
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: skills-sqs-nodeclass
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: KarpenterNodeRole-${CLUSTER_NAME}
  subnetSelectorTerms:
    - id: "${PRIV_A}"
    - id: "${PRIV_B}"
  securityGroupSelectorTerms:
    - id: "${CLUSTER_SG}"
  tags:
    Name: skills-sqs-nodeclass-node
EOF

helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update

helm upgrade --install keda kedacore/keda \
  --version $KEDA_VERSION \
  --namespace $KEDA_NS \
  --set serviceAccount.operator.create=false \
  --set serviceAccount.operator.name=keda-operator \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists \
  --set tolerations[0].effect=NoSchedule \
  --wait

kubectl apply -f "./keda-and-karpenter.yaml"

kubectl get sa keda-operator -n $KEDA_NS -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
kubectl get scaledobject sqs-worker-scaledobject -n $APP_NS
kubectl get ec2nodeclass skills-sqs-nodeclass
kubectl get nodepool skills-sqs-nodepool
echo