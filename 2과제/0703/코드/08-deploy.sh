#!/bin/bash
set -x

APP_NS=skillsmkt
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat <<EOF >> ./app-deploy.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: skillsmkt
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: order-processor-sa
  namespace: skillsmkt
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/skm-app-sqs-role
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-processor
  namespace: skillsmkt
spec:
  replicas: 1
  selector:
    matchLabels:
      app: order-processor
  template:
    metadata:
      labels:
        app: order-processor
    spec:
      serviceAccountName: order-processor-sa
      tolerations:
        - key: skm-app
          operator: Exists
          effect: NoSchedule
      nodeSelector:
        karpenter.sh/nodepool: skm-app-nodepool
      containers:
        - name: order-processor
          image: ${ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com/skm-order-processor:latest
          ports:
            - containerPort: 8080
          env:
            - name: AWS_REGION
              value: ap-northeast-2
            - name: SQS_QUEUE_URL
              value: https://sqs.ap-northeast-2.amazonaws.com/${ACCOUNT_ID}/skm-order-queue
            - name: PROCESSING_TIME
              value: "3"
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
EOF

kubectl apply -f "./app-deploy.yaml"
kubectl wait --for=condition=Available deployment/order-processor \
  -n $APP_NS \
  --timeout=300s

kubectl get pod -n $APP_NS -l app=order-processor -o wide
kubectl get deploy order-processor -n $APP_NS -o jsonpath=\
'{.spec.replicas} {.spec.template.spec.containers[0].ports[0].containerPort} {.spec.template.spec.containers[0].resources.requests.cpu} {.spec.template.spec.containers[0].resources.requests.memory}{"\n"}'
kubectl get deploy order-processor -n $APP_NS -o jsonpath=\
'{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | sort
echo