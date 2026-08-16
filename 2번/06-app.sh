#!/bin/bash
set -x

curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

CLUSTER_NAME="wskorea26-cluster"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# LB Controller
ROLE_NAME="${CLUSTER_NAME}-LBControllerRole"
POLICY_NAME="${CLUSTER_NAME}-LBControllerPolicy"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_OIDC=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed 's/https:\/\///')
aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Federated": "arn:aws:iam::'"$ACCOUNT_ID"':oidc-provider/'"$CLUSTER_OIDC"'"
                },
                "Action": "sts:AssumeRoleWithWebIdentity",
                "Condition": {
                    "StringEquals": {
                        "'"$CLUSTER_OIDC"':aud": "sts.amazonaws.com",
                        "'"$CLUSTER_OIDC"':sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
                    }
                }
            }
        ]
    }' \
    --output json
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
POLICY_ARN=$(aws iam create-policy \
    --policy-name $POLICY_NAME \
    --policy-document file://iam_policy.json \
    --query 'Policy.Arn' --output text)
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cat <<EOF >> service-account.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}
EOF
kubectl apply -f service-account.yaml
rm iam_policy.json
rm service-account.yaml
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh
helm repo add eks https://aws.github.io/eks-charts
helm repo update
rm -f get_helm.sh
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller


# namespace
NAMESPACE="wskorea26"
kubectl create ns $NAMESPACE


# sa
REGION="ap-northeast-2"
CLUSTER_NAME="wskorea26-cluster"
SA_NAME="wsc-sa"
TABLE_ARN=$(aws dynamodb describe-table --table-name wskorea26-data-table --region $REGION --query 'Table.TableArn' --output text)
KMS_KEY_ARN=$(aws kms describe-key --key-id alias/wskorea26-dynamodb-key --region $REGION --query 'KeyMetadata.Arn' --output text)
cat <<EOF > wsc-sa-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DynamoDBPutItemPermission",
            "Effect": "Allow",
            "Action": [
              "dynamodb:PutItem",
              "dynamodb:DescribeTable"
            ],
            "Resource": "$TABLE_ARN"
        },
        {
            "Sid": "KMSKeyPermissionForPut",
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
POLICY_ARN=$(aws iam create-policy \
  --policy-name wskorea26-book-sa-policy \
  --policy-document file://wsc-sa-policy.json \
  --query 'Policy.Arn' --output text)
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --name=$SA_NAME \
  --namespace=$NAMESPACE \
  --attach-policy-arn=$POLICY_ARN \
  --approve \
  --override-existing-serviceaccounts
rm wsc-sa-policy.json


# yaml
REGION="ap-northeast-2"
REPO_NAME="wskorea26-book-repo" 
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:stable"

cat <<EOF > deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: book-deploy
  namespace: wskorea26
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
      tolerations:
      - key: "node-type"
        operator: "Equal"
        value: "app"
        effect: "NoSchedule"
      nodeSelector:
        node-type: app  
      serviceAccountName: wsc-sa
      containers:
        - name: book-ctn
          image: $IMAGE_URI
          ports:
          - containerPort: 8080
          resources:
            limits:
              cpu: 500m
            requests:
              cpu: 200m
EOF

cat <<EOF >> service.yaml
apiVersion: v1
kind: Service
metadata:
  name: book-svc
  namespace: wskorea26
spec:
  selector:
    app: book
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
  type: NodePort
EOF




LAMBDA_ARN=$(aws lambda get-function --function-name wskorea26-book-lambda --query "Configuration.FunctionArn" --output text)
TG_ARN=$(aws elbv2 create-target-group --name wskorea26-lambda-tg --target-type lambda --query "TargetGroups[0].TargetGroupArn" --output text)
aws lambda add-permission --function-name wskorea26-book-lambda --statement-id AllowALBInvoke --action lambda:InvokeFunction --principal elasticloadbalancing.amazonaws.com --source-arn $TG_ARN
aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$LAMBDA_ARN

PUB_SUBNET_C=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-pub-subnet-c" --region $REGION --query "Subnets[0].SubnetId" --output text)
PUB_SUBNET_D=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-pub-subnet-d" --region $REGION --query "Subnets[0].SubnetId" --output text)

cat <<EOF > ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: book-ingress
  namespace: wskorea26
  annotations:
    alb.ingress.kubernetes.io/load-balancer-name: wskorea26-book-alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/subnets: $PUB_SUBNET_C, $PUB_SUBNET_D
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/conditions.book-svc: '[{"field":"http-header","httpHeaderConfig":{"httpHeaderName":"X-Origin-Verify","values":["wskorea26-cf"]}}, {"field":"http-request-method","httpRequestMethodConfig":{"values":["POST"]}}]'
    alb.ingress.kubernetes.io/conditions.reserv-lambda: '[{"field":"http-header","httpHeaderConfig":{"httpHeaderName":"X-Origin-Verify","values":["wskorea26-cf"]}}, {"field":"http-request-method","httpRequestMethodConfig":{"values":["GET"]}}]'
    alb.ingress.kubernetes.io/transforms.book-svc: '[{"type":"url-rewrite","urlRewriteConfig":{"rewrites":[{"regex":"^/book","replace":"/v1/book"}]}}]'
    alb.ingress.kubernetes.io/transforms.reserv-lambda: '[{"type":"url-rewrite","urlRewriteConfig":{"rewrites":[{"regex":"^/book","replace":"/reserv-query"}]}}]'
    alb.ingress.kubernetes.io/actions.reserv-lambda: '{"type":"forward","forwardConfig":{"targetGroups":[{"targetGroupArn":"$TG_ARN","weight":1}]}}'
    alb.ingress.kubernetes.io/actions.response-403: '{"type":"fixed-response","fixedResponseConfig":{"contentType":"text/plain","statusCode":"403","messageBody":"Forbidden"}}'
spec:
  ingressClassName: alb
  defaultBackend:
    service:
      name: response-403
      port:
        name: use-annotation
  rules:
  - http:
      paths:
      - path: /book
        pathType: Prefix
        backend:
          service:
            name: book-svc
            port:
              number: 80
      - path: /book
        pathType: Prefix
        backend:
          service:
            name: reserv-lambda
            port:
              name: use-annotation
EOF

kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml