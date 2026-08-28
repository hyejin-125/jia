cat > 02_push.sh <<'EOF'
#!/bin/bash
set -e

REGION="ap-northeast-2"

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account \
    --output text)

ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "ECR LOGIN"

aws ecr get-login-password \
    --region "$REGION" |
docker login \
    --username AWS \
    --password-stdin "$ECR"

echo "USER"

cat > Dockerfile.user <<'DOCKER'
FROM public.ecr.aws/amazonlinux/amazonlinux:2023

WORKDIR /app

COPY user /app/user

RUN chmod +x /app/user

EXPOSE 8080

CMD ["/app/user"]
DOCKER

docker build \
    -f Dockerfile.user \
    -t apdev-user:latest .

docker tag \
    apdev-user:latest \
    "$ECR/apdev-user:latest"

docker push \
    "$ECR/apdev-user:latest"


echo "PRODUCT"

cat > Dockerfile.product <<'DOCKER'
FROM public.ecr.aws/amazonlinux/amazonlinux:2023

WORKDIR /app

COPY product /app/product

RUN chmod +x /app/product

EXPOSE 8080

CMD ["/app/product"]
DOCKER

docker build \
    -f Dockerfile.product \
    -t apdev-product:latest .

docker tag \
    apdev-product:latest \
    "$ECR/apdev-product:latest"

docker push \
    "$ECR/apdev-product:latest"


echo "STRESS"

cat > Dockerfile.stress <<'DOCKER'
FROM public.ecr.aws/amazonlinux/amazonlinux:2023

WORKDIR /app

COPY stress /app/stress

RUN chmod +x /app/stress

EXPOSE 8080

CMD ["/app/stress"]
DOCKER

docker build \
    -f Dockerfile.stress \
    -t apdev-stress:latest .

docker tag \
    apdev-stress:latest \
    "$ECR/apdev-stress:latest"

docker push \
    "$ECR/apdev-stress:latest"

echo ""
echo "================================"
echo " ECR PUSH COMPLETE"
echo "================================"

aws ecr describe-repositories \
    --region "$REGION" \
    --query 'repositories[].repositoryUri' \
    --output table
EOF

chmod +x 02_push.sh
./02_push.sh
