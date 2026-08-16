#!/bin/bash
set -x

REGION="ap-northeast-2"
export AWS_DEFAULT_REGION="$REGION"

KMS_EKS_ALIAS="alias/wsc2026-eks-kms"
KMS_DB_ALIAS="alias/wsc2026-db-kms"
KMS_ECR_ALIAS="alias/wsc2026-ecr-kms"
KMS_FUNCTION_ALIAS="alias/wsc2026-function-kms"
KMS_BUCKET_ALIAS="alias/wsc2026-bucket-kms"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

get_key_policy_json() {
    cat <<EOF
{
    "Version": "2012-10-17",
    "Id": "key-consolepolicy-3",
    "Statement": [
        {
            "Sid": "Enable IAM Admin And Root Account Without Saying Root Word",
            "Effect": "Allow",
            "Principal": {
                "AWS": "*"
            },
            "Action": [
                "kms:List*",
                "kms:Describe*",
                "kms:Get*",
                "kms:CancelKeyDeletion",
                "kms:ConnectCustomKeyStore",
                "kms:Create*",
                "kms:Delete*",
                "kms:DeriveSharedSecret",
                "kms:Disable*",
                "kms:DisconnectCustomKeyStore",
                "kms:Enable*",
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:Generate*",
                "kms:ImportKeyMaterial",
                "kms:ReEncrypt*",
                "kms:ReplicateKey",
                "kms:RotateKeyOnDemand",
                "kms:ScheduleKeyDeletion",
                "kms:UntagResource",
                "kms:TagResource",
                "kms:RevokeGrant",
                "kms:RetireGrant",
                "kms:PutKeyPolicy",
                "kms:Verify*",
                "kms:Update*",
                "kms:SynchronizeMultiRegionKey",
                "kms:Sign"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "aws:PrincipalAccount": "$ACCOUNT_ID"
                }
            }
        }
    ]
}
EOF
}

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
  else
    ok "기존 키 발견: $keyid"
  fi

  aws kms put-key-policy \
    --key-id "$keyid" \
    --policy-name "default" \
    --policy "$(get_key_policy_json)"

  local arn
  arn=$(aws kms describe-key --key-id "$keyid" --query 'KeyMetadata.Arn' --output text)
  echo "$arn"
}

ensure_key "$KMS_EKS_ALIAS"
ensure_key "$KMS_DB_ALIAS"
ensure_key "$KMS_ECR_ALIAS"
ensure_key "$KMS_FUNCTION_ALIAS"
ensure_key "$KMS_BUCKET_ALIAS"
echo