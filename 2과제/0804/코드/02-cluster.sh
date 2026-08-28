#!/bin/bash
set -x

VPC_ID=$(aws ec2 describe-vpcs --region us-west-2 \
  --filters "Name=tag:Name,Values=*skills-sqs-vpc*" \
  --query "Vpcs[0].VpcId" --output text)
PUB_A=$(aws ec2 describe-subnets --region us-west-2 \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=us-west-2a" "Name=tag:Name,Values=*pub*,*Pub*,*Public*,*public*" \
  --query "Subnets[0].SubnetId" --output text)
PUB_B=$(aws ec2 describe-subnets --region us-west-2 \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=us-west-2b" "Name=tag:Name,Values=*pub*,*Pub*,*Public*,*public*" \
  --query "Subnets[0].SubnetId" --output text)
PRIV_A=$(aws ec2 describe-subnets --region us-west-2 \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=us-west-2a" "Name=tag:Name,Values=*priv*,*Priv*,*Private*,*private*" \
  --query "Subnets[0].SubnetId" --output text)
PRIV_B=$(aws ec2 describe-subnets --region us-west-2 \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=us-west-2b" "Name=tag:Name,Values=*priv*,*Priv*,*Private*,*private*" \
  --query "Subnets[0].SubnetId" --output text)

cat << EOF > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: skills-sqs-cluster
  region: us-west-2
  version: "1.35"

iam:
  withOIDC: true

vpc:
  clusterEndpoints:
    publicAccess: true
    privateAccess: true
  subnets:
    public:
      us-west-2a: { id: "$PUB_A" }
      us-west-2b: { id: "$PUB_B" }
    private:
      us-west-2a: { id: "$PRIV_A" }
      us-west-2b: { id: "$PRIV_B" }

fargateProfiles:
  - name: skills-sqs-fp-keda
    selectors:
      - namespace: keda
  - name: skills-sqs-fp-karpenter
    selectors:
      - namespace: karpenter

managedNodeGroups:
  - name: skills-sqs-ng
    labels: { type: app }
    instanceName: skills-sqs-node
    instanceType: t3.medium
    minSize: 1
    maxSize: 2
    desiredCapacity: 1
    privateNetworking: true
    subnets:
     - us-west-2a
     - us-west-2b
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        awsLoadBalancerController: true
        cloudWatch: true
EOF

curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

eksctl create cluster -f cluster.yaml