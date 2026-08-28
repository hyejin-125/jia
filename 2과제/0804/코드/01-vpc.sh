#!/bin/bash
set -x

aws configure set default.region us-west-2
aws configure set default.output json

VPC=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=skills-sqs-vpc}]' \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames '{"Value":true}'

IGW=$(aws ec2 create-internet-gateway --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=skills-sqs-igw}]' --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC

mksub(){ aws ec2 create-subnet --vpc-id $VPC --cidr-block $2 --availability-zone $3 \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$1}]" --query Subnet.SubnetId --output text; }

PUBA=$(mksub skills-sqs-pub-a   10.0.0.0/24 us-west-2a)
PUBB=$(mksub skills-sqs-pub-b   10.0.1.0/24 us-west-2b)
PRIA=$(mksub skills-sqs-priv-a  10.0.2.0/24 us-west-2a)
PRIB=$(mksub skills-sqs-priv-b  10.0.3.0/24 us-west-2b)

for s in $PUBA $PUBB; do aws ec2 modify-subnet-attribute --subnet-id $s --map-public-ip-on-launch; done

EIPA=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
NATA=$(aws ec2 create-nat-gateway --subnet-id $PUBA --allocation-id $EIPA \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=skills-sqs-nat-a}]' --query NatGateway.NatGatewayId --output text)

EIPB=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
NATB=$(aws ec2 create-nat-gateway --subnet-id $PUBB --allocation-id $EIPB \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=skills-sqs-nat-b}]' --query NatGateway.NatGatewayId --output text)

aws ec2 wait nat-gateway-available --nat-gateway-ids $NATA $NATB

mkrtb(){ aws ec2 create-route-table --vpc-id $VPC --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$1}]" --query RouteTable.RouteTableId --output text; }

PUBRT=$(mkrtb skills-sqs-pub-rt)
PRIART=$(mkrtb skills-sqs-priv-a-rt)
PRIBRT=$(mkrtb skills-sqs-priv-b-rt)

aws ec2 create-route --route-table-id $PUBRT  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
aws ec2 create-route --route-table-id $PRIART --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NATA
aws ec2 create-route --route-table-id $PRIBRT --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NATB

aws ec2 associate-route-table --route-table-id $PUBRT  --subnet-id $PUBA
aws ec2 associate-route-table --route-table-id $PUBRT  --subnet-id $PUBB
aws ec2 associate-route-table --route-table-id $PRIART --subnet-id $PRIA
aws ec2 associate-route-table --route-table-id $PRIBRT --subnet-id $PRIB

aws ec2 create-tags --resources $PUBA $PUBB --tags Key=kubernetes.io/role/elb,Value=1
aws ec2 create-tags --resources $PRIA $PRIB --tags Key=kubernetes.io/role/internal-elb,Value=1 Key=karpenter.sh/discovery,Value=skills-sqs-cluster

aws sqs create-queue \
  --queue-name skills-sqs-queue \
  --attributes VisibilityTimeout=30 \
  --region us-west-2

echo