#!/bin/bash

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "ACCOUNT ID: $ACCOUNT_ID"
aws configure set region ap-southeast-1

read -p "비번호: " NUM
BUCKET_NAME="wsc2026-student-score-bucket-${NUM}"

# 1-1 S3 Bucket + Folder Structure
echo ====================
echo "  1-1 S3 Bucket + Folder Structure"
echo ====================
aws s3api head-bucket --bucket $BUCKET_NAME 2>&1 > /dev/null && aws s3 ls s3://$BUCKET_NAME/

# 1-2 DynamoDB Table + Key Schema
echo ====================
echo "  1-2 DynamoDB Table + Key Schema"
echo ====================
aws dynamodb describe-table --table-name wsc2026-student-score --query "Table.[TableName,KeySchema]" --output json

# 1-3 Lambda Function + Runtime + Env
echo ====================
echo "  1-3 Lambda Function + Runtime + Env"
echo ====================
aws lambda get-function-configuration --function-name wsc2026-student-score-function --query "[FunctionName,Runtime,Environment.Variables]" --output json

# 1-4 Step Functions State Machine
echo ====================
echo "  1-4 Step Functions State Machine"
echo ====================
SM_ARN=$(aws stepfunctions list-state-machines --query "stateMachines[?name=='wsc2026-student-score-workflow'].stateMachineArn" --output text)
aws stepfunctions describe-state-machine --state-machine-arn $SM_ARN --query "[name,type]" --output text

# 1-5-A Workflow Result (Normal)
echo ====================
echo "  1-5-A Workflow Result (Normal)"
echo ====================
aws dynamodb get-item --table-name wsc2026-student-score --key '{"studentId":{"S":"STU1020"},"examDate":{"S":"2026-05-30"}}' --query "Item.[studentId.S,average.N,grade.S]" --output text; aws s3 ls s3://$BUCKET_NAME/processed/

# 1-5-B Workflow Result (Error)
echo ====================
echo "  1-5-B Workflow Result (Error)"
echo ====================
aws s3 ls s3://$BUCKET_NAME/error/
