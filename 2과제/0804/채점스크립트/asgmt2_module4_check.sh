#!/usr/bin/env bash
set -u
export AWS_PAGER=""

OUT_TXT="asgmt2_module4_check_result.txt"
exec > >(tee "$OUT_TXT") 2>&1

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: required command not found: aws" >&2
  exit 2
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. Downloading kubectl to /tmp/kubectl"
  curl -L -s "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /tmp/kubectl || exit 1
  chmod +x /tmp/kubectl
  export PATH="/tmp:$PATH"
fi

echo "== 제2과제 4모듈 Event-driven Pod Scaling with AWS SQS 채점 출력 =="
echo

echo "[4-1] EKS Cluster, VPC, Fargate Profile 구성 (1.25점)"
aws eks describe-cluster --region ap-northeast-2 --name skills-sqs-cluster --query 'cluster.{Name:name,Status:status,Endpoint:endpoint,Version:version,Role:roleArn,Vpc:vpcConfig}' --output table
for FP in skills-sqs-fp-keda skills-sqs-fp-karpenter; do
  echo "fargate_profile=${FP}"
  aws eks describe-fargate-profile --region ap-northeast-2 --cluster-name skills-sqs-cluster --fargate-profile-name "$FP" --query 'fargateProfile.{Name:fargateProfileName,Status:status,Selectors:selectors,Subnets:subnets}' --output table
done
aws eks update-kubeconfig --region ap-northeast-2 --name skills-sqs-cluster
kubectl get nodes -l eks.amazonaws.com/compute-type=fargate -o wide

echo
echo "[4-2] SQS Queue 및 IAM ServiceAccount 구성 (1.25점)"
QUEUE_URL=$(aws sqs get-queue-url --region ap-northeast-2 --queue-name skills-sqs-queue --query QueueUrl --output text 2>/dev/null || true)
echo "QUEUE_URL=${QUEUE_URL}"
aws sqs get-queue-attributes --region ap-northeast-2 --queue-url "$QUEUE_URL" --attribute-names QueueArn VisibilityTimeout FifoQueue --output table
for X in "keda keda-operator" "karpenter karpenter" "skills-sqs sqs-worker-sa"; do
  set -- $X
  echo -n "$1/$2 role="
  kubectl get serviceaccount "$2" -n "$1" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
  echo
done

echo
echo "[4-3] KEDA/Karpenter Controller Fargate 배포 구성 (1.25점)"
kubectl get deployment,pod -n keda -o wide
kubectl get deployment,pod -n karpenter -o wide

echo
echo "[4-4] Worker Application 및 KEDA ScaledObject 구성 (1.25점)"
kubectl get deployment sqs-worker -n skills-sqs -o wide
kubectl get deployment sqs-worker -n skills-sqs -o jsonpath='serviceAccountName={.spec.template.spec.serviceAccountName}{"\n"}selector={.spec.selector.matchLabels}{"\n"}podLabels={.spec.template.metadata.labels}{"\n"}nodeSelector={.spec.template.spec.nodeSelector}{"\n"}env={.spec.template.spec.containers[0].env}{"\n"}image={.spec.template.spec.containers[0].image}{"\n"}'
kubectl get scaledobject sqs-worker-scaledobject -n skills-sqs -o yaml
kubectl get triggerauthentication sqs-worker-trigger-auth -n skills-sqs -o yaml

echo
echo "[4-5] Karpenter NodePool, EC2NodeClass 및 Worker EC2 배치 구성 (1.25점)"
kubectl get nodepool skills-sqs-nodepool -o yaml
kubectl get ec2nodeclass skills-sqs-nodeclass -o yaml
kubectl get nodes -l karpenter.sh/nodepool=skills-sqs-nodepool,skills-nodepool=event-worker -o wide
kubectl get pods -n skills-sqs -l app=sqs-worker -o wide

echo
echo "[4-6] SQS 기반 Scale Out 및 처리 기능 검증 (1.25점)"
echo "주의: 본 항목은 채점기준표에 따라 SQS 메시지 12개를 생성합니다."
if [ -z "$QUEUE_URL" ] || [ "$QUEUE_URL" = "None" ]; then
  echo "skills-sqs-queue Queue URL 식별 실패"
else
  SENT=0
  RUN_ID="skills-scale-out-$(date +%s)"
  for I in $(seq 1 12); do
    aws sqs send-message --region ap-northeast-2 --queue-url "$QUEUE_URL" --message-body "${RUN_ID}-${I}" >/dev/null 2>&1 && SENT=$((SENT + 1))
  done
  echo "sent=${SENT}"
  for T in 60 120 180; do
    sleep 60
    echo "after_${T}s"
    aws sqs get-queue-attributes --region ap-northeast-2 --queue-url "$QUEUE_URL" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed --output table
    kubectl get deployment sqs-worker -n skills-sqs
    kubectl get pods -n skills-sqs -l app=sqs-worker -o wide
    kubectl get nodes -l karpenter.sh/nodepool=skills-sqs-nodepool,skills-nodepool=event-worker -o wide
    kubectl get nodeclaims -l karpenter.sh/nodepool=skills-sqs-nodepool
  done
fi

echo
echo "Result file: ${OUT_TXT}"
