#!/bin/bash
set -x

rm -rf ~/.aws
R=ap-northeast-1
CL=o11y-cluster
T() { echo "Name=$1"; }
echo "== VPC =="
VPC=$(aws ec2 create-vpc --region $R --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=o11y-vpc}]" \
  --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --region $R --vpc-id $VPC --enable-dns-hostnames
aws ec2 modify-vpc-attribute --region $R --vpc-id $VPC --enable-dns-support
echo "VPC=$VPC"

mksn() { # name cidr az
  aws ec2 create-subnet --region $R --vpc-id $VPC --cidr-block $2 --availability-zone $3 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$1}]" \
    --query Subnet.SubnetId --output text
}
PUBA=$(mksn o11y-pub-a 10.0.0.0/24 ${R}a)
PUBC=$(mksn o11y-pub-c 10.0.1.0/24 ${R}c)
PRIA=$(mksn o11y-priv-a 10.0.2.0/24 ${R}a)
PRIC=$(mksn o11y-priv-c 10.0.3.0/24 ${R}c)
echo "PUBA=$PUBA PUBC=$PUBC PRIA=$PRIA PRIC=$PRIC"

for s in $PUBA $PUBC; do
  aws ec2 modify-subnet-attribute --region $R --subnet-id $s --map-public-ip-on-launch >/dev/null
done
# ELB role tags
aws ec2 create-tags --region $R --resources $PUBA $PUBC --tags Key=kubernetes.io/role/elb,Value=1
aws ec2 create-tags --region $R --resources $PRIA $PRIC --tags Key=kubernetes.io/role/internal-elb,Value=1 Key=karpenter.sh/discovery,Value=$CL

echo "== IGW =="
IGW=$(aws ec2 create-internet-gateway --region $R \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=o11y-igw}]" \
  --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --region $R --internet-gateway-id $IGW --vpc-id $VPC

echo "== NAT =="
EIP=$(aws ec2 allocate-address --region $R --domain vpc --query AllocationId --output text)
NAT=$(aws ec2 create-nat-gateway --region $R --subnet-id $PUBA --allocation-id $EIP \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=o11y-nat}]" \
  --query NatGateway.NatGatewayId --output text)
echo "NAT=$NAT waiting..."
aws ec2 wait nat-gateway-available --region $R --nat-gateway-ids $NAT

echo "== Route tables =="
RTPUB=$(aws ec2 create-route-table --region $R --vpc-id $VPC \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=o11y-rt-pub}]" \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --region $R --route-table-id $RTPUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW >/dev/null
aws ec2 associate-route-table --region $R --route-table-id $RTPUB --subnet-id $PUBA >/dev/null
aws ec2 associate-route-table --region $R --route-table-id $RTPUB --subnet-id $PUBC >/dev/null

RTPRI=$(aws ec2 create-route-table --region $R --vpc-id $VPC \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=o11y-rt-priv}]" \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --region $R --route-table-id $RTPRI --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT >/dev/null
aws ec2 associate-route-table --region $R --route-table-id $RTPRI --subnet-id $PRIA >/dev/null
aws ec2 associate-route-table --region $R --route-table-id $RTPRI --subnet-id $PRIC >/dev/null
echo