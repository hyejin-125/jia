#!/bin/bash
set -x

EKS_KEY_ARN=$(aws kms describe-key --key-id alias/wskorea26-eks-key --query 'KeyMetadata.Arn' --output text)
PRIV_SUBNET_C=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-priv-subnet-c" --query "Subnets[0].SubnetId" --output text)
PRIV_SUBNET_D=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-priv-subnet-d" --query "Subnets[0].SubnetId" --output text)

cat <<EOF > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: wskorea26-cluster
  version: "1.35"
  region: ap-northeast-2

secretsEncryption:
  keyARN: $EKS_KEY_ARN

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
  subnets:
    private:
      ap-northeast-2c: { id: $PRIV_SUBNET_C }
      ap-northeast-2d: { id: $PRIV_SUBNET_D }

managedNodeGroups:
  - name: wskorea26-app-ng
    instanceName: wskorea26-app-node
    instanceType: t3.medium
    tags:
      Name: wskorea26-app-node
    desiredCapacity: 2
    minSize: 2
    maxSize: 20
    privateNetworking: true
    labels: 
      node-type: app
    taints:
      - key: node-type
        value: app
        effect: NoSchedule

  - name: wskorea26-addon-ng
    instanceName: wskorea26-addon-node
    tags:
      Name: wskorea26-addon-node
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 20
    privateNetworking: true
    labels: 
      node-type: addon
EOF

curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

eksctl create cluster -f cluster.yaml