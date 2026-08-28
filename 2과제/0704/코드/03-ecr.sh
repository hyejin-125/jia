#!/bin/bash
set -x

export REGION=ap-northeast-1
export ACCT=$(aws sts get-caller-identity --query Account --output text)

aws ecr create-repository --repository-name o11y-log-generator --region $REGION 2>/dev/null

echo "flask>=3.0.0" > requirements.txt
cat > Dockerfile <<'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN pip install boto3
COPY app.py .
EXPOSE 8080
ENV PYTHONUNBUFFERED=1
CMD ["python", "app.py"]
EOF
export ACCT=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region ap-northeast-1 | docker login --username AWS --password-stdin $ACCT.dkr.ecr.ap-northeast-1.amazonaws.com
docker build -t o11y-log-generator .
docker tag o11y-log-generator:latest $ACCT.dkr.ecr.ap-northeast-1.amazonaws.com/o11y-log-generator:v1
docker push $ACCT.dkr.ecr.ap-northeast-1.amazonaws.com/o11y-log-generator:v1