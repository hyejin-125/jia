#!/bin/bash
set -x

REGION="ap-northeast-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# kinesis stream
aws kinesis create-stream \
  --stream-name wsc2026-order-stream \
  --stream-mode-details '{"StreamMode": "ON_DEMAND"}' \
  --region ap-northeast-2

# iam
cat << 'EOF' > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "kinesisanalytics.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
aws iam create-role \
  --role-name wsc2026-analytics-flink-role \
  --assume-role-policy-document file://trust-policy.json 2>/dev/null || true
aws iam attach-role-policy \
  --role-name wsc2026-analytics-flink-role \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
aws iam attach-role-policy \
  --role-name wsc2026-analytics-flink-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonKinesisAnalyticsFullAccess
aws iam attach-role-policy \
  --role-name wsc2026-analytics-flink-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam attach-role-policy \
  --role-name wsc2026-analytics-flink-role \
  --policy-arn arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess
rm -f trust-policy.json

# glue
aws glue create-database \
  --database-input '{
      "Name": "wsc2026_db",
      "Description": "Glue database for WSC 2026 Flink analytics"
  }' \
  --region ap-northeast-2