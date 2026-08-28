#!/bin/bash
set -x

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="ap-northeast-2"

CLUSTER_NAME=skm-eks-cluster
SQS_QUEUE_NAME=skm-order-queue

aws sqs create-queue \
  --queue-name $SQS_QUEUE_NAME \
  --region $REGION \
  --output text

aws sqs get-queue-url --queue-name $SQS_QUEUE_NAME --region $REGION | jq .QueueUrl
echo