#!/bin/bash
set -x

aws configure set cli_pager ""
export AWS_PAGER=""
REGION="eu-west-1"

cat << 'EOF' > ec2-trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role --role-name wsc2026-event-ec2-role --assume-role-policy-document file://ec2-trust.json 2>/dev/null || true
aws iam attach-role-policy --role-name wsc2026-event-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name wsc2026-event-ec2-profile 2>/dev/null || true
aws iam add-role-to-instance-profile --instance-profile-name wsc2026-event-ec2-profile --role-name wsc2026-event-ec2-role 2>/dev/null || true
sleep 5

SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=event-pub-a" --region $REGION --query 'Subnets[0].SubnetId' --output text)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wsc2026-event-sg" --region $REGION --query 'SecurityGroups[0].GroupId' --output text)
AMI_ID=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --region $REGION --query 'Parameter.Value' --output text)

aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.micro \
  --subnet-id $SUBNET_ID \
  --security-group-ids $SG_ID \
  --iam-instance-profile Name=wsc2026-event-ec2-profile \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=wsc2026-event-ec2}]" \
  --region $REGION

rm -f ec2-trust.json

echo