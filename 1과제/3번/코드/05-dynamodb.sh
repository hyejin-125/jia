#!/bin/bash
set -x
export AWS_PAGER=""
REGION="ap-northeast-2"
export AWS_DEFAULT_REGION="$REGION"
TABLE_NAME="wsc2026-book-table"
KMS_ALIAS="alias/wsc2026-db-kms"

LAMBDA_POLICY_NAME="wsc2026-book-function-policy"
LAMBDA_ROLE_NAME="wsc2026-book-function-role"
POD_ROLE_NAME="wsc2026-book-pod-role"

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
KMS_ARN=$(aws kms describe-key --key-id "$KMS_ALIAS" --query 'KeyMetadata.Arn' --output text)
TABLE_ARN="arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"

aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions \
        AttributeName=client_id,AttributeType=S \
        AttributeName=booking_id,AttributeType=S \
    --key-schema \
        AttributeName=client_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --global-secondary-indexes '[
        {
            "IndexName": "booking_id-index",
            "KeySchema": [
                {"AttributeName": "booking_id", "KeyType": "HASH"}
            ],
            "Projection": {
                "ProjectionType": "ALL"
            }
        }
    ]' \
    --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId="$KMS_ARN" \
    --deletion-protection-enabled \
    > /dev/null

aws dynamodb wait table-exists --table-name "$TABLE_NAME"

aws dynamodb update-continuous-backups \
    --table-name "$TABLE_NAME" \
    --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true > /dev/null

EKS_POLICY_JSON=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DynamoDBWriteOnly",
            "Effect": "Allow",
            "Action": [
                "dynamodb:PutItem",
                "dynamodb:BatchWriteItem"
            ],
            "Resource": "$TABLE_ARN"
        },
        {
            "Sid": "KMSAccessForWrite",
            "Effect": "Allow",
            "Action": [
                "kms:Encrypt",
                "kms:GenerateDataKey*"
            ],
            "Resource": "$KMS_ARN"
        }
    ]
}
EOF
)

EKS_POLICY_ARN=$(aws iam create-policy \
    --policy-name "wsc2026-book-pod-policy" \
    --policy-document "$EKS_POLICY_JSON" \
    --query "Policy.Arn" --output text 2>/dev/null || aws iam list-policies --query "Policies[?PolicyName=='wsc2026-book-pod-policy'].Arn" --output text)

POD_TRUST_JSON=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF
)

POD_ROLE_ARN=$(aws iam get-role --role-name "$POD_ROLE_NAME" --query "Role.Arn" --output text 2>/dev/null || \
aws iam create-role \
    --role-name "$POD_ROLE_NAME" \
    --assume-role-policy-document "$POD_TRUST_JSON" \
    --query "Role.Arn" --output text)

aws iam attach-role-policy --role-name "$POD_ROLE_NAME" --policy-arn "$EKS_POLICY_ARN"


LAMBDA_POLICY_JSON=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DynamoDBReadOnly",
            "Effect": "Allow",
            "Action": [
                "dynamodb:GetItem",
                "dynamodb:BatchGetItem",
                "dynamodb:Query",
                "dynamodb:Scan"
            ],
            "Resource": [
                "$TABLE_ARN",
                "$TABLE_ARN/index/*"
            ]
        },
        {
            "Sid": "KMSAccessForRead",
            "Effect": "Allow",
            "Action": [
                "kms:Decrypt"
            ],
            "Resource": "$KMS_ARN"
        }
    ]
}
EOF
)

LAMBDA_POLICY_ARN=$(aws iam create-policy \
    --policy-name "$LAMBDA_POLICY_NAME" \
    --policy-document "$LAMBDA_POLICY_JSON" \
    --query "Policy.Arn" --output text 2>/dev/null || aws iam list-policies --query "Policies[?PolicyName=='${LAMBDA_POLICY_NAME}'].Arn" --output text)

LAMBDA_TRUST_JSON=$(cat <<EOF
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
)

LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query "Role.Arn" --output text 2>/dev/null || \
aws iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document "$LAMBDA_TRUST_JSON" \
    --query "Role.Arn" --output text)

aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-arn "$LAMBDA_POLICY_ARN"

sleep 15

FIXED_POLICY_JSON=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPodWrite",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:role/${POD_ROLE_NAME}"
      },
      "Action": "dynamodb:PutItem",
      "Resource": "${TABLE_ARN}",
      "Condition": {
        "ArnEquals": {
          "aws:PrincipalArn": "arn:aws:iam::${ACCOUNT_ID}:role/${POD_ROLE_NAME}"
        }
      }
    },
    {
      "Sid": "AllowLambdaQuery",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
      },
      "Action": "dynamodb:Query",
      "Resource": "${TABLE_ARN}",
      "Condition": {
        "ArnEquals": {
          "aws:PrincipalArn": "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
        }
      }
    }
  ]
}
EOF
)

aws dynamodb put-resource-policy \
    --resource-arn "$TABLE_ARN" \
    --policy "$FIXED_POLICY_JSON" > /dev/null


KMS_KEY_ID=$(aws kms list-aliases \
  --query "Aliases[?AliasName=='alias/wsc2026-function-kms'].TargetKeyId" \
  --output text)
aws kms get-key-policy \
  --key-id "$KMS_KEY_ID" \
  --policy-name "default" \
  --query "Policy" \
  --output text | jq '.Statement' > temp_statements.json

cat <<EOF > lambda_statement.json
[
  {
    "Sid": "AllowLambdaToUseKey",
    "Effect": "Allow",
    "Principal": {
      "Service": "lambda.amazonaws.com"
    },
    "Action": [
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ],
    "Resource": "*"
  }
]
EOF

jq -n --slurpfile orig temp_statements.json --slurpfile lamb lambda_statement.json \
  '{Version: "2012-10-17", Id: "key-consolepolicy-3", Statement: ($orig[0] + $lamb[0])}' > final_policy.json

aws kms put-key-policy \
  --key-id "$KMS_KEY_ID" \
  --policy-name "default" \
  --policy file://final_policy.json

rm -f temp_statements.json lambda_statement.json final_policy.json