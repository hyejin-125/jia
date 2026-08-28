#!/bin/bash
set -x

REGION="ap-southeast-1"
ROLE_NAME="bigbae-lambda-audit-role"
FUNCTION_NAME="bigbae-nosql-reservation-audit"
TABLE_NAME="bigbae-nosql-reservation-table"
AUDIT_TABLE="bigbae-nosql-audit-table"

cat << 'EOF' > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://trust-policy.json
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
sleep 15

ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)

cat << 'EOF' > lambda_function.py
import os
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.types import TypeDeserializer

AUDIT_TABLE_NAME = os.environ.get("AUDIT_TABLE_NAME", "bigbae-nosql-audit-table")

dynamodb = boto3.resource("dynamodb")
audit_table = dynamodb.Table(AUDIT_TABLE_NAME)
_deserializer = TypeDeserializer()


def _deserialize_image(image: dict | None) -> dict:
    if not image:
        return {}
    return {key: _deserializer.deserialize(value) for key, value in image.items()}


def handler(event, context):
    for record in event.get("Records", []):
        new_image = _deserialize_image(record["dynamodb"].get("NewImage"))
        old_image = _deserialize_image(record["dynamodb"].get("OldImage"))
        image = new_image or old_image

        audit_table.put_item(
            Item={
                "event_id": str(uuid.uuid4()),
                "train_id": image.get("train_id"),
                "seat_id": image.get("seat_id"),
                "user_id": image.get("user_id"),
                "occurred_at": datetime.now(timezone.utc).isoformat(),
                "stream_event": record.get("eventName"),
                "old_status": old_image.get("status"),
                "new_status": new_image.get("status"),
            }
        )

    return {"statusCode": 200}
EOF

zip function.zip lambda_function.py

aws lambda create-function \
    --function-name $FUNCTION_NAME \
    --runtime python3.13 \
    --role $ROLE_ARN \
    --handler lambda_function.handler \
    --zip-file fileb://function.zip \
    --timeout 30 \
    --environment "Variables={AUDIT_TABLE_NAME=$AUDIT_TABLE}" \
    --region $REGION

STREAM_ARN=$(aws dynamodb describe-table \
    --table-name $TABLE_NAME \
    --region $REGION \
    --query 'Table.LatestStreamArn' \
    --output text)

UUID=$(aws lambda create-event-source-mapping \
    --function-name $FUNCTION_NAME \
    --event-source-arn $STREAM_ARN \
    --starting-position LATEST \
    --region $REGION \
    --query 'UUID' \
    --output text)

aws lambda update-event-source-mapping \
    --uuid "$UUID" \
    --enabled \
    --region $REGION

echo