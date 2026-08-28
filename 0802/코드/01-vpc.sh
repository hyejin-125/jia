#!/bin/bash
set -x

REGION="ap-northeast-1"
AZ1=$(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[0].ZoneName' --output text)
AZ2=$(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[1].ZoneName' --output text)

CLIENT_VPC_ID=$(aws ec2 create-vpc --region $REGION --cidr-block 10.61.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=skills-lattice-client-vpc}]' --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --region $REGION --vpc-id $CLIENT_VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --region $REGION --vpc-id $CLIENT_VPC_ID --enable-dns-support

CLIENT_IGW_ID=$(aws ec2 create-internet-gateway --region $REGION --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=skills-lattice-client-igw}]' --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --region $REGION --vpc-id $CLIENT_VPC_ID --internet-gateway-id $CLIENT_IGW_ID

CLIENT_PUB_SUB1_ID=$(aws ec2 create-subnet --region $REGION --vpc-id $CLIENT_VPC_ID --cidr-block 10.61.1.0/24 --availability-zone $AZ1 --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=skills-lattice-client-pub-1}]' --query 'Subnet.SubnetId' --output text)
CLIENT_PUB_SUB2_ID=$(aws ec2 create-subnet --region $REGION --vpc-id $CLIENT_VPC_ID --cidr-block 10.61.2.0/24 --availability-zone $AZ2 --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=skills-lattice-client-pub-2}]' --query 'Subnet.SubnetId' --output text)

aws ec2 modify-subnet-attribute --region $REGION --subnet-id $CLIENT_PUB_SUB1_ID --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --region $REGION --subnet-id $CLIENT_PUB_SUB2_ID --map-public-ip-on-launch

CLIENT_PUB_RT_ID=$(aws ec2 create-route-table --region $REGION --vpc-id $CLIENT_VPC_ID --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=skills-lattice-client-pub-rt}]' --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --region $REGION --route-table-id $CLIENT_PUB_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $CLIENT_IGW_ID
aws ec2 associate-route-table --region $REGION --subnet-id $CLIENT_PUB_SUB1_ID --route-table-id $CLIENT_PUB_RT_ID
aws ec2 associate-route-table --region $REGION --subnet-id $CLIENT_PUB_SUB2_ID --route-table-id $CLIENT_PUB_RT_ID

SERVICE_VPC_ID=$(aws ec2 create-vpc --region $REGION --cidr-block 10.62.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=skills-lattice-service-vpc}]' --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --region $REGION --vpc-id $SERVICE_VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --region $REGION --vpc-id $SERVICE_VPC_ID --enable-dns-support

SERVICE_IGW_ID=$(aws ec2 create-internet-gateway --region $REGION --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=skills-lattice-service-igw}]' --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --region $REGION --vpc-id $SERVICE_VPC_ID --internet-gateway-id $SERVICE_IGW_ID

SERVICE_PUB_SUB1_ID=$(aws ec2 create-subnet --region $REGION --vpc-id $SERVICE_VPC_ID --cidr-block 10.62.1.0/24 --availability-zone $AZ1 --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=skills-lattice-service-pub-1}]' --query 'Subnet.SubnetId' --output text)
SERVICE_PUB_SUB2_ID=$(aws ec2 create-subnet --region $REGION --vpc-id $SERVICE_VPC_ID --cidr-block 10.62.2.0/24 --availability-zone $AZ2 --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=skills-lattice-service-pub-2}]' --query 'Subnet.SubnetId' --output text)

SERVICE_PRIV_SUB1_ID=$(aws ec2 create-subnet --region $REGION --vpc-id $SERVICE_VPC_ID --cidr-block 10.62.10.0/24 --availability-zone $AZ1 --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=skills-lattice-service-priv-1}]' --query 'Subnet.SubnetId' --output text)
SERVICE_PRIV_SUB2_ID=$(aws ec2 create-subnet --region $REGION --vpc-id $SERVICE_VPC_ID --cidr-block 10.62.20.0/24 --availability-zone $AZ2 --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=skills-lattice-service-priv-2}]' --query 'Subnet.SubnetId' --output text)

aws ec2 modify-subnet-attribute --region $REGION --subnet-id $SERVICE_PUB_SUB1_ID --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --region $REGION --subnet-id $SERVICE_PUB_SUB2_ID --map-public-ip-on-launch

SERVICE_PUB_RT_ID=$(aws ec2 create-route-table --region $REGION --vpc-id $SERVICE_VPC_ID --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=skills-lattice-service-pub-rt}]' --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --region $REGION --route-table-id $SERVICE_PUB_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $SERVICE_IGW_ID
aws ec2 associate-route-table --region $REGION --subnet-id $SERVICE_PUB_SUB1_ID --route-table-id $SERVICE_PUB_RT_ID
aws ec2 associate-route-table --region $REGION --subnet-id $SERVICE_PUB_SUB2_ID --route-table-id $SERVICE_PUB_RT_ID

SERVICE_EIP_ID=$(aws ec2 allocate-address --region $REGION --domain vpc --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=skills-lattice-service-nat-eip}]' --query 'AllocationId' --output text)
SERVICE_NAT_ID=$(aws ec2 create-nat-gateway --region $REGION --allocation-id $SERVICE_EIP_ID --subnet-id $SERVICE_PUB_SUB1_ID --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=skills-lattice-service-nat}]' --query 'NatGateway.NatGatewayId' --output text)

echo "Waiting for NAT Gateway to become available..."
aws ec2 wait nat-gateway-available --region $REGION --nat-gateway-ids $SERVICE_NAT_ID

SERVICE_PRIV_RT_ID=$(aws ec2 create-route-table --region $REGION --vpc-id $SERVICE_VPC_ID --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=skills-lattice-service-priv-rt}]' --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --region $REGION --route-table-id $SERVICE_PRIV_RT_ID --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $SERVICE_NAT_ID
aws ec2 associate-route-table --region $REGION --subnet-id $SERVICE_PRIV_SUB1_ID --route-table-id $SERVICE_PRIV_RT_ID
aws ec2 associate-route-table --region $REGION --subnet-id $SERVICE_PRIV_SUB2_ID --route-table-id $SERVICE_PRIV_RT_ID