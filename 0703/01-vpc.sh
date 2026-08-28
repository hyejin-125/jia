#!/bin/bash
set -x

rm -rf ~/.aws
R=ap-northeast-2
CL=skm-eks-cluster
T() { echo "Name=$1"; }
VPC=$(aws ec2 create-vpc --region $R --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=skm-vpc}]" \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --region $R --vpc-id $VPC --enable-dns-hostnames
aws ec2 modify-vpc-attribute --region $R --vpc-id $VPC --enable-dns-support

mksn() { # name cidr az
  aws ec2 create-subnet --region $R --vpc-id $VPC --cidr-block $2 --availability-zone $3 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$1}]" \
    --query Subnet.SubnetId --output text
}
PUBA=$(mksn skm-pub-a 10.0.0.0/24 ${R}a)
PUBC=$(mksn skm-pub-c 10.0.1.0/24 ${R}c)
PRIA=$(mksn skm-priv-a 10.0.10.0/24 ${R}a)
PRIC=$(mksn skm-priv-c 10.0.11.0/24 ${R}c)

for s in $PUBA $PUBC; do
  aws ec2 modify-subnet-attribute --region $R --subnet-id $s --map-public-ip-on-launch >/dev/null
done
aws ec2 create-tags --region $R --resources $PUBA $PUBC --tags Key=kubernetes.io/role/elb,Value=1
aws ec2 create-tags --region $R --resources $PRIA $PRIC --tags Key=kubernetes.io/role/internal-elb,Value=1 Key=karpenter.sh/discovery,Value=$CL Key=kubernetes.io/cluster/skm-eks-cluster,Value=owned

IGW=$(aws ec2 create-internet-gateway --region $R \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=skm-igw}]" \
  --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --region $R --internet-gateway-id $IGW --vpc-id $VPC

EIP=$(aws ec2 allocate-address --region $R --domain vpc --query AllocationId --output text)
NAT=$(aws ec2 create-nat-gateway --region $R --subnet-id $PUBA --allocation-id $EIP \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=skm-nat}]" \
  --query NatGateway.NatGatewayId --output text)
aws ec2 wait nat-gateway-available --region $R --nat-gateway-ids $NAT

RTPUB=$(aws ec2 create-route-table --region $R --vpc-id $VPC \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=skm-rt-pub}]" \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --region $R --route-table-id $RTPUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW >/dev/null
aws ec2 associate-route-table --region $R --route-table-id $RTPUB --subnet-id $PUBA >/dev/null
aws ec2 associate-route-table --region $R --route-table-id $RTPUB --subnet-id $PUBC >/dev/null

RTPRI=$(aws ec2 create-route-table --region $R --vpc-id $VPC \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=skm-rt-priv}]" \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --region $R --route-table-id $RTPRI --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT >/dev/null
aws ec2 associate-route-table --region $R --route-table-id $RTPRI --subnet-id $PRIA >/dev/null
aws ec2 associate-route-table --region $R --route-table-id $RTPRI --subnet-id $PRIC >/dev/null
echo