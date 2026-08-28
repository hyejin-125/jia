#!/bin/bash
set -x

REGION="ap-southeast-1"
INSTANCE_NAME="bigbae-nosql-app-ec2"
INSTANCE_type="t3.micro"
ROLE_NAME="bigbae-ec2-dynamodb-role"
PROFILE_NAME="bigbae-ec2-dynamodb-profile"
SG_NAME="bigbae-app-sg"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=bigbae-vpc" --region $REGION --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=bigbae-pub-a" --region $REGION --query 'Subnets[0].SubnetId' --output text)

SG_ID=$(aws ec2 create-security-group \
    --group-name $SG_NAME \
    --description "Security group for Flask app on port 8080" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --query 'GroupId' \
    --output text)

aws ec2 create-tags --resources $SG_ID --tags Key=Name,Value=bigbae-app-sg --region $REGION

aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8080 --cidr 0.0.0.0/0 --region $REGION
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION

cat << 'EOF' > ec2-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://ec2-trust-policy.json
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess

aws iam create-instance-profile --instance-profile-name $PROFILE_NAME
aws iam add-role-to-instance-profile --instance-profile-name $PROFILE_NAME --role-name $ROLE_NAME

sleep 10

AMI_ID=$(aws ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --region $REGION \
    --query 'Parameter.Value' \
    --output text)

cat << 'EOF' > user-data.sh
#!/bin/bash
yum update -y
yum install -y python3-pip

cat << 'INNER_EOF' > /home/ec2-user/app.py
import os
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError
from flask import Flask, jsonify, request

app = Flask(__name__)

AWS_REGION = os.environ.get("AWS_REGION", "ap-southeast-1")
TABLE_NAME = os.environ.get("TABLE_NAME", "bigbae-nosql-reservation-table")
GSI_NAME = os.environ.get("GSI_NAME", "gsi-user-reservations")

table = boto3.resource("dynamodb", region_name=AWS_REGION).Table(TABLE_NAME)


@app.route("/healthcheck", methods=["GET"])
def healthcheck():
    return "", 200


@app.route("/reserve", methods=["POST"])
def reserve():
    body = request.get_json(silent=True) or {}
    train_id = body.get("train_id")
    seat_id = body.get("seat_id")
    user_id = body.get("user_id")

    if not train_id or not seat_id or not user_id:
        return jsonify({"error": "invalid request"}), 400

    reserved_at = datetime.now(timezone.utc).isoformat()

    try:
        response = table.update_item(
            Key={"train_id": train_id, "seat_id": seat_id},
            UpdateExpression=(
                "SET #status = :reserved, #version = if_not_exists(#version, :zero) + :one, "
                "user_id = :user_id, reserved_at = :reserved_at"
            ),
            ConditionExpression="attribute_not_exists(#status) OR #status = :available",
            ExpressionAttributeNames={"#status": "status", "#version": "version"},
            ExpressionAttributeValues={
                ":reserved": "reserved",
                ":available": "available",
                ":zero": 0,
                ":one": 1,
                ":user_id": user_id,
                ":reserved_at": reserved_at,
            },
            ReturnValues="ALL_NEW",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return jsonify({"error": "already reserved"}), 409
        raise

    item = response["Attributes"]
    return (
        jsonify(
            {
                "status": "reserved",
                "seat_id": seat_id,
                "version": int(item["version"]),
            }
        ),
        200,
    )


@app.route("/cancel", methods=["POST"])
def cancel():
    body = request.get_json(silent=True) or {}
    train_id = body.get("train_id")
    seat_id = body.get("seat_id")
    user_id = body.get("user_id")

    if not train_id or not seat_id or not user_id:
        return jsonify({"error": "invalid request"}), 400

    try:
        table.update_item(
            Key={"train_id": train_id, "seat_id": seat_id},
            UpdateExpression=(
                "SET #status = :available, #version = if_not_exists(#version, :zero) + :one "
                "REMOVE user_id, reserved_at"
            ),
            ConditionExpression="#status = :reserved AND user_id = :user_id",
            ExpressionAttributeNames={"#status": "status", "#version": "version"},
            ExpressionAttributeValues={
                ":available": "available",
                ":reserved": "reserved",
                ":zero": 0,
                ":one": 1,
                ":user_id": user_id,
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return jsonify({"error": "not owner"}), 409
        raise

    return jsonify({"status": "cancelled", "seat_id": seat_id}), 200


@app.route("/seats/<train_id>", methods=["GET"])
def seats(train_id):
    response = table.query(KeyConditionExpression=Key("train_id").eq(train_id))
    items = []
    for item in response.get("Items", []):
        items.append(
            {
                "seat_id": item["seat_id"],
                "status": item.get("status", "available"),
                "user_id": item.get("user_id"),
            }
        )
    return jsonify(items), 200


@app.route("/my-bookings/<user_id>", methods=["GET"])
def my_bookings(user_id):
    response = table.query(
        IndexName=GSI_NAME,
        KeyConditionExpression=Key("user_id").eq(user_id),
    )
    items = []
    for item in response.get("Items", []):
        items.append(
            {
                "train_id": item["train_id"],
                "seat_id": item["seat_id"],
                "reserved_at": item["reserved_at"],
            }
        )
    return jsonify(items), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
INNER_EOF

chown ec2-user:ec2-user /home/ec2-user/app.py
cd /home/ec2-user
pip3 install --ignore-installed boto3>=1.35.0 flask>=3.0.0 "jmespath<1.1.0,>=0.7.1" "python-dateutil<=2.9.0,>=2.1"

export AWS_REGION="ap-southeast-1"
export TABLE_NAME="bigbae-nosql-reservation-table"
export GSI_NAME="gsi-user-reservations"

nohup python3 app.py > app.log 2>&1 &
EOF

aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type $INSTANCE_type \
    --subnet-id $SUBNET_ID \
    --security-group-ids $SG_ID \
    --iam-instance-profile Name=$PROFILE_NAME \
    --user-data file://user-data.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --region $REGION

echo