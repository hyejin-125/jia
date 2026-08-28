#!/bin/bash
set -x

R="ap-northeast-2"
VPC=$(aws ec2 describe-vpcs --region $R --filters "Name=tag:Name,Values=skm-vpc" --query "Vpcs[0].VpcId" --output text)
PUBA=$(aws ec2 describe-subnets --region $R --filters "Name=tag:Name,Values=skm-pub-a" --query "Subnets[0].SubnetId" --output text)
PUBC=$(aws ec2 describe-subnets --region $R --filters "Name=tag:Name,Values=skm-pub-c" --query "Subnets[0].SubnetId" --output text)
PRIA=$(aws ec2 describe-subnets --region $R --filters "Name=tag:Name,Values=skm-priv-a" --query "Subnets[0].SubnetId" --output text)
PRIC=$(aws ec2 describe-subnets --region $R --filters "Name=tag:Name,Values=skm-priv-c" --query "Subnets[0].SubnetId" --output text)

cat <<EOF > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: skm-eks-cluster
  region: ap-northeast-2
  version: "1.35"
  tags:
    Project: skillsmarket

vpc:
  id: "${VPC}"
  subnets:
    public:
      ap-northeast-2a: { id: "${PUBA}" }
      ap-northeast-2c: { id: "${PUBC}" }
    private:
      ap-northeast-2a: { id: "${PRIA}" }
      ap-northeast-2c: { id: "${PRIC}" }

iam:
  withOIDC: true

managedNodeGroups:
  - name: skm-cluster-addon-ng
    instanceType: t3.medium
    minSize: 1
    desiredCapacity: 1
    maxSize: 1
    privateNetworking: true
    amiFamily: AmazonLinux2023
    tags:
      Name: skm-cluster-addon-ng-node
    taints:
      - key: CriticalAddonsOnly
        value: "true"
        effect: NoSchedule
    iam:
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
EOF

curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

eksctl create cluster -f cluster.yaml