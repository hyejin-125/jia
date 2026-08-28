#!/bin/bash
set -x

REGION="ap-northeast-2"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=analytics-vpc" --query "Vpcs[0].VpcId" --output text --region ${REGION})
PUB_A_ID=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=analytics-pub-a" --query "Subnets[0].SubnetId" --output text --region ${REGION})
PUB_B_ID=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=analytics-pub-b" --query "Subnets[0].SubnetId" --output text --region ${REGION})
PRIV_A_ID=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=analytics-priv-a" --query "Subnets[0].SubnetId" --output text --region ${REGION})

cat << 'EOF' > ec2-trust-policy.json
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

aws iam create-role --role-name wsc2026-ec2-ssm-role --assume-role-policy-document file://ec2-trust-policy.json
aws iam attach-role-policy --role-name wsc2026-ec2-ssm-role --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
aws iam create-instance-profile --instance-profile-name wsc2026-ec2-profile
aws iam add-role-to-instance-profile --instance-profile-name wsc2026-ec2-profile --role-name wsc2026-ec2-ssm-role
rm -f ec2-trust-policy.json

sleep 5

ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name analytics-alb-sg \
    --description "Security group for ALB" \
    --vpc-id ${VPC_ID} \
    --query 'GroupId' \
    --output text \
    --region ${REGION})

aws ec2 authorize-security-group-ingress \
    --group-id ${ALB_SG_ID} \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region ${REGION}

EC2_SG_ID=$(aws ec2 create-security-group \
    --group-name analytics-ec2-sg \
    --description "Security group for EC2 application" \
    --vpc-id ${VPC_ID} \
    --query 'GroupId' \
    --output text \
    --region ${REGION})

aws ec2 authorize-security-group-ingress \
    --group-id ${EC2_SG_ID} \
    --protocol tcp --port 5000 --source-group ${ALB_SG_ID} \
    --region ${REGION}

TG_ARN=$(aws elbv2 create-target-group \
    --name wsc2026-analytics-tg \
    --protocol HTTP \
    --port 5000 \
    --vpc-id ${VPC_ID} \
    --target-type instance \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text \
    --region ${REGION})

ALB_ARN=$(aws elbv2 create-load-balancer \
    --name wsc2026-analytics-alb \
    --subnets ${PUB_A_ID} ${PUB_B_ID} \
    --security-groups ${ALB_SG_ID} \
    --scheme internet-facing \
    --type application \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text \
    --region ${REGION})

aws elbv2 create-listener \
    --load-balancer-arn ${ALB_ARN} \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=${TG_ARN} \
    --region ${REGION}

AMI_ID=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query 'Parameters[0].Value' --output text --region ${REGION})


cat << 'EOF' > user-data.sh
#!/bin/bash
mkdir -p /opt/app
cd /opt/app

cat << 'INNER_EOF' > app.py
import json
import os
import random
import uuid
from datetime import datetime, timezone

import boto3
from flask import Flask, jsonify

app = Flask(__name__)

STREAM_NAME = os.environ.get("STREAM_NAME")
REGION = os.environ.get("AWS_REGION")

if not STREAM_NAME or not REGION:
    raise RuntimeError("STREAM_NAME and AWS_REGION environment variables are required")

kinesis = boto3.client("kinesis", region_name=REGION)

PRODUCTS = [
    {"name": "Laptop", "price": 1200000},
    {"name": "Mouse", "price": 25000},
    {"name": "Keyboard", "price": 55000},
    {"name": "Monitor", "price": 350000},
    {"name": "Headset", "price": 89000},
]


def generate_order():
    product = random.choice(PRODUCTS)
    return {
        "order_id": str(uuid.uuid4()),
        "product_name": product["name"],
        "price": product["price"],
        "quantity": random.randint(1, 5),
        "event_time": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
    }


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"})


@app.route("/order", methods=["POST"])
def create_order():
    order = generate_order()
    kinesis.put_record(
        StreamName=STREAM_NAME,
        Data=json.dumps(order),
        PartitionKey=order["order_id"],
    )
    return jsonify(order), 201


@app.route("/orders/generate", methods=["POST"])
def generate_orders():
    count = 10
    orders = []
    for _ in range(count):
        order = generate_order()
        kinesis.put_record(
            StreamName=STREAM_NAME,
            Data=json.dumps(order),
            PartitionKey=order["order_id"],
        )
        orders.append(order)
    return jsonify({"generated": count, "orders": orders}), 201


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
INNER_EOF

yum install python3-pip -y
pip3 install flask boto3 gunicorn

tee /etc/systemd/system/app.service > /dev/null << 'INNER_EOF'
[Unit]
Description=Flask Application for Grading
After=network.target

[Service]
User=root
WorkingDirectory=/opt/app
Environment="STREAM_NAME=wsc2026-order-stream"
Environment="AWS_REGION=ap-northeast-2"
ExecStart=/usr/bin/python3 /opt/app/app.py
Restart=always

[Install]
WantedBy=multi-user.target
INNER_EOF

systemctl daemon-reload
systemctl enable app
systemctl start app
EOF

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id ${AMI_ID} \
    --instance-type t3.small \
    --subnet-id ${PRIV_A_ID} \
    --security-group-ids ${EC2_SG_ID} \
    --iam-instance-profile Name=wsc2026-ec2-profile \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=wsc2026-analytics-ec2}]' \
    --user-data file://user-data.sh \
    --query 'Instances[0].InstanceId' \
    --output text \
    --region ${REGION})

aws ec2 wait instance-running --instance-ids ${INSTANCE_ID} --region ${REGION}

aws elbv2 register-targets \
    --target-group-arn ${TG_ARN} \
    --targets Id=${INSTANCE_ID} \
    --region ${REGION}
