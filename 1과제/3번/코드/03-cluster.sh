#!/bin/bash
set -x

REGION="ap-northeast-2"
export AWS_DEFAULT_REGION="$REGION"

KMS_EKS_ALIAS="alias/wsc2026-eks-kms"
SG_NAME="wsc2026-eks-sg"

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=wsc2026-skills-vpc" \
  --query "Vpcs[0].VpcId" --output text)

SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text)

SECURITY_GROUP_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Security group for wsc2026 EKS Cluster" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME}]" \
  --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$SECURITY_GROUP_ID" \
  --protocol all \
  --cidr 0.0.0.0/0 2>/dev/null || true

KMS_ARN=$(aws kms describe-key --key-id "$KMS_EKS_ALIAS" --query 'KeyMetadata.Arn' --output text)

SUBNET_2A_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=wsc2026-skills-app-sub-a" "Name=availability-zone,Values=ap-northeast-2a" \
  --query "Subnets[0].SubnetId" --output text)

SUBNET_2B_ID=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=wsc2026-skills-app-sub-b" "Name=availability-zone,Values=ap-northeast-2b" \
  --query "Subnets[0].SubnetId" --output text)

cat <<EOF > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: wsc2026-eks-cluster
  version: "1.35"
  region: ap-northeast-2

secretsEncryption:
  keyARN: $KMS_ARN

cloudWatch:
  clusterLogging:
    enableTypes: ["*"]

iam:
  withOIDC: true
  serviceAccounts:
  - metadata:
      name: aws-load-balancer-controller
      namespace: kube-system
    wellKnownPolicies:
      awsLoadBalancerController: true
  - metadata:
      name: cert-manager
      namespace: cert-manager
    wellKnownPolicies:
      certManager: true

vpc:
  securityGroup: $SECURITY_GROUP_ID
  subnets:
    private:
      ap-northeast-2a: { id: $SUBNET_2A_ID }
      ap-northeast-2b: { id: $SUBNET_2B_ID }
  clusterEndpoints:
    publicAccess: false
    privateAccess: true
      
managedNodeGroups:
  - name: wsc2026-workload-ng
    labels: { wsc2026/node: application }
    instanceName: wsc2026-workload-node
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 20
    privateNetworking: true
    amiFamily: AmazonLinux2023

  - name: wsc2026-addon-nodegroup
    labels: { wsc2026/node: addon }
    instanceName: wsc2026-addon-node
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 20
    privateNetworking: true
    amiFamily: AmazonLinux2023
EOF

curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

eksctl create cluster -f cluster.yaml