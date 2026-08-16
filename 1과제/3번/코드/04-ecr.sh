#!/bin/bash
set -x
REGION="ap-northeast-2"
export AWS_DEFAULT_REGION="$REGION"

ECR_NAME="wsc2026-book-ecr"
KMS_ALIAS="alias/wsc2026-ecr-kms"
IMAGE_TAG="v1.0.0"

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
KMS_ARN=$(aws kms describe-key --key-id "$KMS_ALIAS" --query 'KeyMetadata.Arn' --output text)
REPOSITORY_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_NAME}"

aws ecr create-repository \
    --repository-name "$ECR_NAME" \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=KMS,kmsKey="$KMS_ARN" > /dev/null

LIFECYCLE_POLICY=$(cat <<EOF
{
    "rules": [
        {
            "rulePriority": 1,
            "description": "Keep v1 prefixed images",
            "selection": {
                "tagStatus": "tagged",
                "tagPrefixList": ["v1"],
                "countType": "imageCountMoreThan",
                "countNumber": 999
            },
            "action": {
                "type": "expire"
            }
        },
        {
            "rulePriority": 2,
            "description": "Expire other images older than 14 days",
            "selection": {
                "tagStatus": "any",
                "countType": "sinceImagePushed",
                "countUnit": "days",
                "countNumber": 14
            },
            "action": {
                "type": "expire"
            }
        }
    ]
}
EOF
)

aws ecr put-lifecycle-policy \
    --repository-name "$ECR_NAME" \
    --lifecycle-policy-text "$LIFECYCLE_POLICY" > /dev/null
echo

chmod 777 book
cat <<EOF > Dockerfile
FROM alpine:latest
WORKDIR /app
COPY ./book /app/main
RUN apk update && \\
  apk add --no-cache libc6-compat libstdc++ libgcc curl openssl && \\
  apk upgrade --no-cache busybox && \\
  chmod +x /app/main
EXPOSE 8080
CMD ["/app/main"]
EOF
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com"
docker build -t "wsc2026-book-ecr:v1.0.0" .
docker tag "wsc2026-book-ecr:v1.0.0" "${ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com/wsc2026-book-ecr:v1.0.0"
docker push "${ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com/wsc2026-book-ecr:v1.0.0"
echo