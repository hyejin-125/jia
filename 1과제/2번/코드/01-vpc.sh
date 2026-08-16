#!/bin/bash
set -x

aws configure set default.region ap-northeast-2
aws configure set default.output json

VPC=$(aws ec2 create-vpc --cidr-block 172.16.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=wskorea26-vpc}]' \
  --query Vpc.VpcId --output text)

aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames '{"Value":true}'

IGW=$(aws ec2 create-internet-gateway --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=book-igw}]' --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC

mksub(){ 
  aws ec2 create-subnet --vpc-id $VPC --cidr-block $2 --availability-zone $3 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$1}]" --query Subnet.SubnetId --output text
}

PUB_C=$(mksub wskorea26-pub-subnet-c   172.16.1.0/24   ap-northeast-2c)
PUB_D=$(mksub wskorea26-pub-subnet-d   172.16.2.0/24   ap-northeast-2d)
PRIV_C=$(mksub wskorea26-priv-subnet-c 172.16.201.0/24 ap-northeast-2c)
PRIV_D=$(mksub wskorea26-priv-subnet-d 172.16.202.0/24 ap-northeast-2d)

for s in $PUB_C $PUB_D; do 
  aws ec2 modify-subnet-attribute --subnet-id $s --map-public-ip-on-launch
done

EIP_C=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
NGW_C=$(aws ec2 create-nat-gateway --subnet-id $PUB_C --allocation-id $EIP_C \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=book-ngw-c}]' --query NatGateway.NatGatewayId --output text)

EIP_D=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
NGW_D=$(aws ec2 create-nat-gateway --subnet-id $PUB_D --allocation-id $EIP_D \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=book-ngw-d}]' --query NatGateway.NatGatewayId --output text)

aws ec2 wait nat-gateway-available --nat-gateway-ids $NGW_C $NGW_D

mkrtb(){ 
  aws ec2 create-route-table --vpc-id $VPC --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$1}]" --query RouteTable.RouteTableId --output text
}

PUBLIC_RT=$(mkrtb wskorea26-public-rtb)
PRIVATE_RT_C=$(mkrtb wskorea26-private-rtb-c)
PRIVATE_RT_D=$(mkrtb wskorea26-private-rtb-d)

aws ec2 create-route --route-table-id $PUBLIC_RT     --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
aws ec2 create-route --route-table-id $PRIVATE_RT_C  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NGW_C
aws ec2 create-route --route-table-id $PRIVATE_RT_D  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NGW_D

aws ec2 associate-route-table --route-table-id $PUBLIC_RT     --subnet-id $PUB_C
aws ec2 associate-route-table --route-table-id $PUBLIC_RT     --subnet-id $PUB_D
aws ec2 associate-route-table --route-table-id $PRIVATE_RT_C  --subnet-id $PRIV_C
aws ec2 associate-route-table --route-table-id $PRIVATE_RT_D  --subnet-id $PRIV_D

aws ec2 create-tags --resources $PUB_C $PUB_D --tags Key=kubernetes.io/role/elb,Value=1
aws ec2 create-tags --resources $PRIV_C $PRIV_D --tags Key=kubernetes.io/role/internal-elb,Value=1 Key=karpenter.sh/discovery,Value=wskorea26-cluster
