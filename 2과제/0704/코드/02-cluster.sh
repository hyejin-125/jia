#!/bin/bash
set -x

R="ap-northeast-1"
VPC=$(aws ec2 describe-vpcs --region $R --filters "Name=tag:Name,Values=o11y-vpc" --query "Vpcs[0].VpcId" --output text)
PUBA=$(aws ec2 describe-subnets --region $R --filters "Name=tag:Name,Values=o11y-pub-a" --query "Subnets[0].SubnetId" --output text)
PUBC=$(aws ec2 describe-subnets --region $R --filters "Name=tag:Name,Values=o11y-pub-c" --query "Subnets[0].SubnetId" --output text)
PRIA=$(aws ec2 describe-subnets --region $R --filters "Name=tag:Name,Values=o11y-priv-a" --query "Subnets[0].SubnetId" --output text)
PRIC=$(aws ec2 describe-subnets --region $R --filters "Name=tag:Name,Values=o11y-priv-c" --query "Subnets[0].SubnetId" --output text)

cat <<EOF > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: o11y-cluster
  region: ap-northeast-1
  version: "1.35"

vpc:
  id: "${VPC}"
  subnets:
    public:
      ap-northeast-1a: { id: "${PUBA}" }
      ap-northeast-1c: { id: "${PUBC}" }
    private:
      ap-northeast-1a: { id: "${PRIA}" }
      ap-northeast-1c: { id: "${PRIC}" }

iam:
  withOIDC: true

managedNodeGroups:
  - name: o11y-ng
    instanceType: t3.medium
    amiFamily: AmazonLinux2023
    minSize: 2
    maxSize: 2
    desiredCapacity: 2
    privateNetworking: true
    preBootstrapCommands:
      - "timedatectl set-timezone Asia/Seoul"
    tags:
      Name: o11y-node
    propagateASGTags: true

addons:
  - name: vpc-cni
  - name: kube-proxy
  - name: coredns
  - name: aws-ebs-csi-driver
    wellKnownPolicies:
      ebsCSIController: true
EOF

curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

eksctl create cluster -f cluster.yaml