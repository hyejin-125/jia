#!/bin/bash
set -x

rm -rf ~/.aws
REGION="ap-southeast-1"
CIDR_VPC="10.0.0.0/16"
CIDR_SUBNET="10.0.1.0/24"

VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $CIDR_VPC \
    --region $REGION \
    --query 'Vpc.VpcId' \
    --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=bigbae-vpc --region $REGION

IGW_ID=$(aws ec2 create-internet-gateway \
    --region $REGION \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)
aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=bigbae-igw --region $REGION
aws ec2 attach-internet-gateway \
    --vpc-id $VPC_ID \
    --internet-gateway-id $IGW_ID \
    --region $REGION

SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block $CIDR_SUBNET \
    --region $REGION \
    --query 'Subnet.SubnetId' \
    --output text)
aws ec2 create-tags --resources $SUBNET_ID --tags Key=Name,Value=bigbae-pub-a --region $REGION
aws ec2 modify-subnet-attribute \
    --subnet-id $SUBNET_ID \
    --map-public-ip-on-launch \
    --region $REGION

RT_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --region $REGION \
    --query 'RouteTable.RouteTableId' \
    --output text)
aws ec2 create-tags --resources $RT_ID --tags Key=Name,Value=bigbae-pub-rt --region $REGION
aws ec2 create-route \
    --route-table-id $RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID \
    --region $REGION

aws ec2 associate-route-table \
    --route-table-id $RT_ID \
    --subnet-id $SUBNET_ID \
    --region $REGION

echo