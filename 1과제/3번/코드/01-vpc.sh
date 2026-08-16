#!/bin/bash
set -x

aws configure set default.region ap-northeast-2
aws configure set default.output json

VPC=$(aws ec2 create-vpc --cidr-block 192.168.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=wsc2026-skills-vpc}]' \
  --query Vpc.VpcId --output text)

aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames '{"Value":true}'

IGW=$(aws ec2 create-internet-gateway --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=wsc2026-skills-igw}]' --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC

mksub(){ aws ec2 create-subnet --vpc-id $VPC --cidr-block $2 --availability-zone $3 \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$1}]" --query Subnet.SubnetId --output text; }

HUB_A=$(mksub wsc2026-skills-hub-sub-a   192.168.1.0/24  ap-northeast-2a)
HUB_B=$(mksub wsc2026-skills-hub-sub-b   192.168.10.0/24 ap-northeast-2b)
APP_A=$(mksub wsc2026-skills-app-sub-a   192.168.2.0/24  ap-northeast-2a)
APP_B=$(mksub wsc2026-skills-app-sub-b   192.168.20.0/24 ap-northeast-2b)

for s in $HUB_A $HUB_B; do aws ec2 modify-subnet-attribute --subnet-id $s --map-public-ip-on-launch; done

EIPA=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
NATA=$(aws ec2 create-nat-gateway --subnet-id $HUB_A --allocation-id $EIPA \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=wsc2026-skills-nat-a}]' --query NatGateway.NatGatewayId --output text)

EIPB=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
NATB=$(aws ec2 create-nat-gateway --subnet-id $HUB_B --allocation-id $EIPB \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=wsc2026-skills-nat-b}]' --query NatGateway.NatGatewayId --output text)

aws ec2 wait nat-gateway-available --nat-gateway-ids $NATA $NATB

mkrtb(){ aws ec2 create-route-table --vpc-id $VPC --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$1}]" --query RouteTable.RouteTableId --output text; }

HUB_RT=$(mkrtb wsc2026-skills-hub-rtb)
APP_A_RT=$(mkrtb wsc2026-skills-app-rtb-a)
APP_B_RT=$(mkrtb wsc2026-skills-app-rtb-b)

aws ec2 create-route --route-table-id $HUB_RT   --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
aws ec2 create-route --route-table-id $APP_A_RT --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NATA
aws ec2 create-route --route-table-id $APP_B_RT --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NATB

aws ec2 associate-route-table --route-table-id $HUB_RT   --subnet-id $HUB_A
aws ec2 associate-route-table --route-table-id $HUB_RT   --subnet-id $HUB_B
aws ec2 associate-route-table --route-table-id $APP_A_RT --subnet-id $APP_A
aws ec2 associate-route-table --route-table-id $APP_B_RT --subnet-id $APP_B

aws ec2 create-tags --resources $HUB_A $HUB_B --tags Key=kubernetes.io/role/elb,Value=1
aws ec2 create-tags --resources $APP_A $APP_B --tags Key=kubernetes.io/role/internal-elb,Value=1 Key=karpenter.sh/discovery,Value=wsc2026-eks-cluster

SG_ID=$(aws ec2 create-security-group \
  --group-name "mark-sg" \
  --description "Security group with any open ingress" \
  --vpc-id "$VPC" \
  --region "ap-northeast-2" \
  --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol "-1" \
  --port -1 \
  --cidr "0.0.0.0/0" \
  --region "ap-northeast-2"