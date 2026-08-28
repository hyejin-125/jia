#!/bin/bash
set -x

REGION="ap-southeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
TIMESTAMP=$(date +%s)

VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=skills-ceh-vpc" --query "Vpcs[0].VpcId" --output text)
if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    echo "skills-ceh-vpc를 찾을 수 없습니다."
    exit 1
fi
echo "VPC ID: $VPC_ID"

SUB_ID=$(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=skills-ceh-pub-1" --query "Subnets[0].SubnetId" --output text)
echo "Subnet ID: $SUB_ID"


PROTECTED_SG_ID=$(aws ec2 create-security-group --region $REGION \
    --group-name "skills-ceh-protected-sg-$TIMESTAMP" \
    --description "Protected Security Group for CEH Remediation" \
    --vpc-id $VPC_ID \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=skills-ceh-protected-sg}]' \
    --query "GroupId" --output text)
echo "Protected Security Group ID: $PROTECTED_SG_ID"


AMI_ID=$(aws ssm get-parameters --region $REGION --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query "Parameters[0].Value" --output text)
echo "AMI ID: $AMI_ID"


EC2_ID=$(aws ec2 run-instances --region $REGION \
    --image-id $AMI_ID \
    --instance-type t3.micro \
    --subnet-id $SUB_ID \
    --security-group-ids $PROTECTED_SG_ID \
    --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=skills-ceh-ec2}]' \
    --query "Instances[0].InstanceId" --output text)