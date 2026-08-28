#!/bin/bash
set -x

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-west-2"
ECR_REPO_NAME=skills-sqs-ecr
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"

aws ecr create-repository \
  --repository-name $ECR_REPO_NAME \
  --region $REGION \
  --output text 2>/dev/null || echo "ECR repo already exists"

chmod 777 worker.py
cat <<EOF >> Dockerfile
FROM python:3.9-slim
WORKDIR /app
COPY worker.py .
RUN pip install boto3
CMD ["python", "worker.py"]
EOF
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.us-west-2.amazonaws.com
docker build -t skills-sqs-ecr .
docker tag skills-sqs-ecr:latest $ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/skills-sqs-ecr:latest
docker push $ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/skills-sqs-ecr:latest