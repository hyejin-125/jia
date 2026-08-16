#!/bin/bash
set -x

REGION="ap-northeast-2"
CLUSTER_NAME="wskorea26-cluster"
NAMESPACE="monitoring"

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

PUB_SUBNET_C=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-pub-subnet-c" --region $REGION --query "Subnets[0].SubnetId" --output text)
PUB_SUBNET_D=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-pub-subnet-d" --region $REGION --query "Subnets[0].SubnetId" --output text)

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add aws https://aws.github.io/eks-charts
helm repo update

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --name=fluent-bit \
  --namespace=$NAMESPACE \
  --attach-policy-arn=arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --approve \
  --override-existing-serviceaccounts

cat <<EOF > prometheus-values.yaml
prometheusOperator:
  nodeSelector:
    node-type: addon

prometheus:
  prometheusSpec:
    nodeSelector:
      node-type: addon

alertmanager:
  alertmanagerSpec:
    nodeSelector:
      node-type: addon

kube-state-metrics:
  nodeSelector:
    node-type: addon

grafana:
  adminUser: "skills-${BNUM}-admin"
  adminPassword: '\\\$korea26!!'
  nodeSelector:
    node-type: addon
  defaultDashboardsEnabled: false

prometheus-node-exporter:
  tolerations:
    - key: "node-type"
      operator: "Equal"
      value: "app"
      effect: "NoSchedule"
EOF

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace $NAMESPACE \
  -f prometheus-values.yaml






cat <<EOF > fluentbit-values.yaml
serviceAccount:
  create: false
  name: fluent-bit

tolerations:
- key: "node-type"
  operator: "Equal"
  value: "app"
  effect: "NoSchedule"

cloudWatchLogs:
  enabled: true
  region: "$REGION"
  logGroupName: "/aws/eks/${CLUSTER_NAME}/pods-logs"
  autoCreateGroup: true
  logStreamPrefix: "fluentbit-"
EOF

helm upgrade --install fluent-bit aws/aws-for-fluent-bit \
  --namespace $NAMESPACE \
  -f fluentbit-values.yaml





cat <<EOF > grafana-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    alb.ingress.kubernetes.io/load-balancer-name: wskorea26-grafana-alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/subnets: $PUB_SUBNET_C,$PUB_SUBNET_D
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /login
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: monitoring-grafana
            port:
              number: 80
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: wskorea26-monitoring-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  wskorea26-monitoring.json: |
    {
      "annotations": { "list": [] },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 0,
      "id": null,
      "uid": "wskorea26",
      "links": [],
      "liveNow": false,
      "panels": [
        {
          "id": 1,
          "title": "컨테이너의 CPU 사용량",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
          "datasource": {"type": "prometheus"},
          "targets": [
            {
              "expr": "sum(rate(container_cpu_usage_seconds_total{container!=''}[5m])) by (container, pod)",
              "refId": "A"
            }
          ]
        },
        {
          "id": 2,
          "title": "컨테이너의 메모리 사용량",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
          "datasource": {"type": "prometheus"},
          "targets": [
            {
              "expr": "sum(container_memory_working_set_bytes{container!=''}) by (container, pod)",
              "refId": "A"
            }
          ]
        },
        {
          "id": 3,
          "title": "실행중인 Pod 개수",
          "type": "stat",
          "gridPos": {"h": 8, "w": 8, "x": 0, "y": 8},
          "datasource": {"type": "prometheus"},
          "targets": [
            {
              "expr": "count(kube_pod_status_phase{phase='Running'})",
              "refId": "A"
            }
          ]
        },
        {
          "id": 4,
          "title": "컨테이너의 재시작 횟수",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 8, "x": 8, "y": 8},
          "datasource": {"type": "prometheus"},
          "targets": [
            {
              "expr": "sum(kube_pod_container_status_restarts_total) by (container, pod)",
              "refId": "A"
            }
          ]
        },
        {
          "id": 5,
          "title": "컨테이너의 네트워크 트래픽 수신량",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 8, "x": 16, "y": 8},
          "datasource": {"type": "prometheus"},
          "targets": [
            {
              "expr": "sum(rate(container_network_receive_bytes_total[5m])) by (pod)",
              "refId": "A"
            }
          ]
        }
      ],
      "refresh": "5s",
      "schemaVersion": 38,
      "style": "dark",
      "tags": [],
      "time": {
        "from": "now-1h",
        "to": "now"
      },
      "timepicker": {},
      "timezone": "",
      "title": "wskorea26-monitoring",
      "version": 1
    }
EOF

kubectl apply -f grafana-ingress.yaml