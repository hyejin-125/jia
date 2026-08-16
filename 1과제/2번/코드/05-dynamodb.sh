#!/bin/bash
set -x

export AWS_PAGER=""
REGION="ap-northeast-2"
DDB_KEY_ARN=$(aws kms describe-key --key-id alias/wskorea26-dynamodb-key --region $REGION --query 'KeyMetadata.Arn' --output text)

aws dynamodb create-table \
    --table-name wskorea26-data-table \
    --attribute-definitions AttributeName=client_id,AttributeType=S \
    --key-schema AttributeName=client_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --deletion-protection-enabled \
    --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId=$DDB_KEY_ARN \
    --region $REGION



TABLE_ARN=$(aws dynamodb describe-table \
    --table-name wskorea26-data-table \
    --region $REGION \
    --query 'Table.TableArn' --output text)

KMS_KEY_ARN=$(aws kms describe-key \
    --key-id alias/wskorea26-dynamodb-key \
    --region $REGION \
    --query 'KeyMetadata.Arn' --output text)

cat <<EOF > lambda-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DynamoDBGetItemPermission",
            "Effect": "Allow",
            "Action": [
                "dynamodb:GetItem",
                "dynamodb:Scan"
            ],
            "Resource": "$TABLE_ARN"
        },
        {
            "Sid": "KMSDecryptPermission",
            "Effect": "Allow",
            "Action": [
                "kms:Decrypt",
                "kms:DescribeKey",
                "kms:GenerateDataKey",
                "kms:GenerateDataKeyWithoutPlaintext"
            ],
            "Resource": "$KMS_KEY_ARN"
        }
    ]
}
EOF

cat <<EOF > lambda-trust-policy.json
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

POLICY_ARN=$(aws iam create-policy \
    --policy-name wskorea26-book-lambda-policy \
    --policy-document file://lambda-policy.json \
    --query 'Policy.Arn' --output text)
aws iam create-role \
    --role-name wskorea26-book-lambda-role \
    --assume-role-policy-document file://lambda-trust-policy.json
aws iam attach-role-policy \
    --role-name wskorea26-book-lambda-role \
    --policy-arn $POLICY_ARN
rm lambda-policy.json lambda-trust-policy.json