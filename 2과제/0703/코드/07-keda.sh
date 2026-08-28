#!/bin/bash
set -x

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="ap-northeast-2"

APP_NS=skillsmkt
KEDA_NS=keda
KEDA_VERSION=2.16.1
KEDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/skm-keda-sqs-role"

kubectl create namespace $APP_NS --dry-run=client -o yaml | kubectl apply -f -
cat <<EOF > ./keda-and-karpenter.yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-sqs-auth
  namespace: skillsmkt
spec:
  podIdentity:
    provider: aws-eks
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: order-scaler
  namespace: skillsmkt
spec:
  scaleTargetRef:
    name: order-processor
  minReplicaCount: 1
  maxReplicaCount: 5
  cooldownPeriod: 10
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 10
          policies:
            - type: Percent
              value: 100
              periodSeconds: 10
  triggers:
    - type: aws-sqs-queue
      authenticationRef:
        name: keda-sqs-auth
      metadata:
        queueURL: https://sqs.ap-northeast-2.amazonaws.com/${ACCOUNT_ID}/skm-order-queue
        queueLength: "5"
        awsRegion: ap-northeast-2
        identityOwner: operator
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: skm-app-nodepool
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: skm-app-nodeclass
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.small", "t3.medium"]
      taints:
        - key: skm-app
          value: "true"
          effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: skm-app-nodeclass
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: KarpenterNodeRole-skm-eks-cluster
  subnetSelectorTerms:
    - tags:
        kubernetes.io/cluster/skm-eks-cluster: "*"
  securityGroupSelectorTerms:
    - tags:
        alpha.eksctl.io/cluster-name: skm-eks-cluster
  tags:
    Name: skm-app-nodeclass-node
EOF

# Helm 레포 추가 및 KEDA 설치
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update

helm upgrade --install keda kedacore/keda \
  --version $KEDA_VERSION \
  --namespace $KEDA_NS \
  --create-namespace \
  --set "serviceAccount.operator.annotations.eks\.amazonaws\.com/role-arn=${KEDA_ROLE_ARN}" \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists \
  --set tolerations[0].effect=NoSchedule \
  --wait

kubectl get pod -n $KEDA_NS -l app.kubernetes.io/name=keda-operator

kubectl apply -f "./keda-and-karpenter.yaml"

kubectl get scaledobject order-scaler -n $APP_NS
kubectl get ec2nodeclass
kubectl get nodepool
echo
