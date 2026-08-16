#!/bin/bash
set -x

REGION="ap-northeast-2"
export AWS_DEFAULT_REGION="$REGION"

KMS_S3_ALIAS="alias/wskorea26-s3-key"
KMS_ECR_ALIAS="alias/wskorea26-ecr-key"
KMS_DDB_ALIAS="alias/wskorea26-dynamodb-key"
KMS_EKS_ALIAS="alias/wskorea26-eks-key"

ensure_key() {
  local alias="$1" name="${1#alias/}"
  local keyid
  keyid=$(aws kms list-aliases --query "Aliases[?AliasName=='${alias}'].TargetKeyId" --output text)
  if [ -z "$keyid" ] || [ "$keyid" = "None" ]; then
    keyid=$(aws kms create-key \
      --description "$name" \
      --tags TagKey=Name,TagValue=$name \
      --query 'KeyMetadata.KeyId' --output text)
    aws kms create-alias --alias-name "$alias" --target-key-id "$keyid"
  fi
  local arn; arn=$(aws kms describe-key --key-id "$keyid" --query 'KeyMetadata.Arn' --output text)
  echo "$arn"
}

S3_KEY_ARN=$(ensure_key "$KMS_S3_ALIAS");
ECR_KEY_ARN=$(ensure_key "$KMS_ECR_ALIAS");
DDB_KEY_ARN=$(ensure_key "$KMS_DDB_ALIAS");
EKS_KEY_ARN=$(ensure_key "$KMS_EKS_ALIAS");