#!/bin/bash
set -x

rm -rf ~/.aws
REGION="ap-northeast-2"
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block 10.20.0.0/16 \
    --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=analytics-vpc}]' \
    --query 'Vpc.VpcId' \
    --output text \
    --region ${REGION})

aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-hostnames '{"Value": true}' --region ${REGION}
aws ec2 modify-vpc-attribute --vpc-id ${VPC_ID} --enable-dns-support '{"Value": true}' --region ${REGION}

IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=analytics-igw}]' \
    --query 'InternetGateway.InternetGatewayId' \
    --output text \
    --region ${REGION})

aws ec2 attach-internet-gateway \
    --vpc-id ${VPC_ID} \
    --internet-gateway-id ${IGW_ID} \
    --region ${REGION}

PUB_A_ID=$(aws ec2 create-subnet \
    --vpc-id ${VPC_ID} \
    --cidr-block 10.20.0.0/24 \
    --availability-zone ${REGION}a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=analytics-pub-a}]' \
    --query 'Subnet.SubnetId' \
    --output text \
    --region ${REGION})
aws ec2 modify-subnet-attribute --subnet-id ${PUB_A_ID} --map-public-ip-on-launch --region ${REGION}

PUB_B_ID=$(aws ec2 create-subnet \
    --vpc-id ${VPC_ID} \
    --cidr-block 10.20.1.0/24 \
    --availability-zone ${REGION}c \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=analytics-pub-b}]' \
    --query 'Subnet.SubnetId' \
    --output text \
    --region ${REGION})
aws ec2 modify-subnet-attribute --subnet-id ${PUB_B_ID} --map-public-ip-on-launch --region ${REGION}

PRIV_A_ID=$(aws ec2 create-subnet \
    --vpc-id ${VPC_ID} \
    --cidr-block 10.20.100.0/24 \
    --availability-zone ${REGION}a \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=analytics-priv-a}]' \
    --query 'Subnet.SubnetId' \
    --output text \
    --region ${REGION})

PRIV_B_ID=$(aws ec2 create-subnet \
    --vpc-id ${VPC_ID} \
    --cidr-block 10.20.101.0/24 \
    --availability-zone ${REGION}c \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=analytics-priv-b}]' \
    --query 'Subnet.SubnetId' \
    --output text \
    --region ${REGION})

PUB_RTB_ID=$(aws ec2 create-route-table \
    --vpc-id ${VPC_ID} \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=analytics-pub-rtb}]' \
    --query 'RouteTable.RouteTableId' \
    --output text \
    --region ${REGION})

aws ec2 create-route \
    --route-table-id ${PUB_RTB_ID} \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id ${IGW_ID} \
    --region ${REGION}

aws ec2 associate-route-table --route-table-id ${PUB_RTB_ID} --subnet-id ${PUB_A_ID} --region ${REGION}
aws ec2 associate-route-table --route-table-id ${PUB_RTB_ID} --subnet-id ${PUB_B_ID} --region ${REGION}

EIP_ALLOC_ID=$(aws ec2 allocate-address \
    --domain vpc \
    --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=analytics-ngw-eip}]' \
    --query 'AllocationId' \
    --output text \
    --region ${REGION})

NGW_ID=$(aws ec2 create-nat-gateway \
    --allocation-id ${EIP_ALLOC_ID} \
    --subnet-id ${PUB_A_ID} \
    --query 'NatGateway.NatGatewayId' \
    --output text \
    --region ${REGION})

aws ec2 create-tags \
    --resources ${NGW_ID} \
    --tags Key=Name,Value=analytics-ngw \
    --region ${REGION}

aws ec2 wait nat-gateway-available --nat-gateway-ids ${NGW_ID} --region ${REGION}

PRIV_A_RTB_ID=$(aws ec2 create-route-table \
    --vpc-id ${VPC_ID} \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=analytics-priv-a-rtb}]' \
    --query 'RouteTable.RouteTableId' \
    --output text \
    --region ${REGION})

aws ec2 create-route \
    --route-table-id ${PRIV_A_RTB_ID} \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id ${NGW_ID} \
    --region ${REGION}

aws ec2 associate-route-table --route-table-id ${PRIV_A_RTB_ID} --subnet-id ${PRIV_A_ID} --region ${REGION}

PRIV_B_RTB_ID=$(aws ec2 create-route-table \
    --vpc-id ${VPC_ID} \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=analytics-priv-b-rtb}]' \
    --query 'RouteTable.RouteTableId' \
    --output text \
    --region ${REGION})

aws ec2 create-route \
    --route-table-id ${PRIV_B_RTB_ID} \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id ${NGW_ID} \
    --region ${REGION}

aws ec2 associate-route-table --route-table-id ${PRIV_B_RTB_ID} --subnet-id ${PRIV_B_ID} --region ${REGION}