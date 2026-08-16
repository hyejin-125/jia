#!/bin/bash
set -x

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION_CODE="ap-northeast-2"
EKS_CLUSTER_NAME="wsc2026-eks-cluster"
APP_EKS_NODE_GROUP_NAME="wsc2026-workload-node"
ALB_SECURITY_GROUP_NAME="wsc2026-app-alb-sg"
POD_ROLE_NAME="wsc2026-book-pod-role"
KMS_KEY_ALIASE_NAME="alias/wsc2026-db-kms"

kubectl get configmaps coredns -n kube-system -o yaml > coredns.yaml
sed -i "s|cluster.local|wsc2026.skills.local|g" ./coredns.yaml
kubectl apply -f ./coredns.yaml --force
rm -rf ./coredns.yaml
kubectl rollout restart deploy/coredns -n kube-system

kubectl create ns wsc2026 --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns observability --dry-run=client -o yaml | kubectl apply -f -

aws eks create-addon \
  --cluster-name wsc2026-eks-cluster \
  --addon-name eks-pod-identity-agent \
  --resolve-conflicts OVERWRITE

TRUST_POLICY=$(cat <<EOF
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

aws iam create-role --role-name "$POD_ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" 2>/dev/null || true
aws iam attach-role-policy --role-name "$POD_ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"

KMS_KEY_ARN=$(aws kms describe-key --key-id "$KMS_KEY_ALIASE_NAME" --query "KeyMetadata.Arn" --output text --region "$REGION_CODE")
aws iam put-role-policy \
  --role-name "$POD_ROLE_NAME" \
  --policy-name wsc2026-dynamodb-kms-policy \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
        {
            \"Sid\": \"DynamoDBReadWrite\",
            \"Effect\": \"Allow\",
            \"Action\": [
                \"dynamodb:PutItem\",
                \"dynamodb:BatchWriteItem\",
                \"dynamodb:GetItem\",
                \"dynamodb:Query\",
                \"dynamodb:Scan\",
                \"dynamodb:UpdateItem\"
            ],
            \"Resource\": \"arn:aws:dynamodb:ap-northeast-2:${ACCOUNT_ID}:table/wsc2026-book-table\"
        },
        {
            \"Sid\": \"KMSAccessForBook\",
            \"Effect\": \"Allow\",
            \"Action\": [
                \"kms:Encrypt\",
                \"kms:Decrypt\",
                \"kms:DescribeKey\",
                \"kms:GenerateDataKey*\"
            ],
            \"Resource\": \"${KMS_KEY_ARN}\"
        }
    ]
}"

kubectl create serviceaccount wsc2026-book-sa -n wsc2026 --dry-run=client -o yaml | kubectl apply -f -

aws eks create-pod-identity-association \
  --cluster-name "$EKS_CLUSTER_NAME" \
  --namespace "wsc2026" \
  --service-account "wsc2026-book-sa" \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${POD_ROLE_NAME}" 2>/dev/null || ok "Association already exists."

ECR_NAME="wsc2026-book-ecr"
IMAGE_TAG="v1.0.0"
IMAGE_URL="${ACCOUNT_ID}.dkr.ecr.${REGION_CODE}.amazonaws.com/${ECR_NAME}:${IMAGE_TAG}"

cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: book-config
  namespace: wsc2026
data:
  AWS_REGION: ap-northeast-2
  TABLE_NAME: wsc2026-book-table
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: wsc2026-book-pdb
  namespace: wsc2026
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: book
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wsc2026-book-deploy
  namespace: wsc2026
  labels:
    app: book
spec:
  replicas: 2
  selector:
    matchLabels:
      app: book
  template:
    metadata:
      labels:
        app: book
    spec:
      serviceAccountName: wsc2026-book-sa
      containers:
        - name: wsc2026-book-cnt
          image: $IMAGE_URL
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
            limits:
              cpu: "250m"
              memory: "512Mi"
          env:
            - name: AWS_REGION
              valueFrom:
                configMapKeyRef:
                  name: book-config
                  key: AWS_REGION
            - name: TABLE_NAME
              valueFrom:
                configMapKeyRef:
                  name: book-config
                  key: TABLE_NAME
          startupProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 0
            periodSeconds: 5
            timeoutSeconds: 10
            failureThreshold: 12
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 0
            periodSeconds: 5
            timeoutSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 0
            periodSeconds: 5
            timeoutSeconds: 10
            failureThreshold: 6
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: book
      nodeSelector:
        wsc2026/node: application
---
apiVersion: v1
kind: Service
metadata:
  name: wsc2026-book-svc
  namespace: wsc2026
  annotations:
    service.kubernetes.io/topology-mode: "Auto"
spec:
  selector:
    app: book
  ports:
    - protocol: TCP
      port: 8080
      targetPort: 8080
EOF

cat <<EOF > values.yaml
image:
  repository: 602401143452.dkr.ecr.ap-northeast-2.amazonaws.com/amazon/aws-load-balancer-controller

serviceAccount:
  create: false
  name: aws-load-balancer-controller

cluster:
  dnsDomain: wsc2026.skills.local

nodeSelector:
  wsc2026/node: addon

enableShield: false
enableWaf: false
enableWafv2: false
EOF

eksctl utils associate-iam-oidc-provider --region $REGION_CODE --cluster $EKS_CLUSTER_NAME --approve

if ! command -v helm &> /dev/null; then
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
    chmod +x get_helm.sh
    ./get_helm.sh
    rm -f get_helm.sh
fi

helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$EKS_CLUSTER_NAME \
  -f ./values.yaml
rm -f values.yaml

sleep 15

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=wsc2026-skills-vpc" --query "Vpcs[0].VpcId" --output text)
PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" --query "PrefixLists[0].PrefixListId" --output text)

SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$ALB_SECURITY_GROUP_NAME" "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[0].GroupId" --output text)
if [ -z "$SECURITY_GROUP_ID" ] || [ "$SECURITY_GROUP_ID" = "None" ]; then
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
      --group-name "$ALB_SECURITY_GROUP_NAME" \
      --description "Security group for Application ALB restricted to CloudFront" \
      --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$ALB_SECURITY_GROUP_NAME}]" \
      --query "GroupId" --output text)
    echo "새 보안 그룹 생성됨: $SECURITY_GROUP_ID"
else
    echo "기존 보안 그룹 발견: $SECURITY_GROUP_ID"
fi

aws ec2 authorize-security-group-ingress \
  --group-id "$SECURITY_GROUP_ID" \
  --ip-permissions "[
    {
      \"IpProtocol\": \"tcp\",
      \"FromPort\": 80,
      \"ToPort\": 80,
      \"PrefixListIds\": [{\"PrefixListId\": \"$PREFIX_LIST_ID\"}]
    }
  ]" 2>/dev/null || true

NODE_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=*wsc2026*node*" --query "SecurityGroups[0].GroupId" --output text)
if [ -z "$NODE_SG_ID" ] || [ "$NODE_SG_ID" = "None" ]; then
    NODE_SG_ID=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
fi

aws ec2 authorize-security-group-ingress \
  --group-id "$NODE_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$SECURITY_GROUP_ID" 2>/dev/null || true

cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wsc2026-book-ingress
  namespace: wsc2026
  annotations:
    alb.ingress.kubernetes.io/load-balancer-name: wsc2026-app-alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/security-groups: $SECURITY_GROUP_ID
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: '5'
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: '3'
    alb.ingress.kubernetes.io/healthy-threshold-count: '3'
    alb.ingress.kubernetes.io/unhealthy-threshold-count: '2'
    alb.ingress.kubernetes.io/target-group-attributes: deregistration_delay.timeout_seconds=30
    alb.ingress.kubernetes.io/actions.response-403: >
      {"type":"fixed-response","fixedResponseConfig":{"contentType":"text/plain","statusCode":"403","messageBody":"Restrict access to api"}}
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /v1/book
        pathType: Prefix
        backend:
          service:
            name: wsc2026-book-svc
            port:
              number: 8080
      - path: /health
        pathType: Prefix
        backend:
          service:
            name: wsc2026-book-svc
            port:
              number: 8080
EOF

echo