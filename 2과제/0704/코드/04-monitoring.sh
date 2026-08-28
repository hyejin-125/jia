#!/bin/bash
set -x

export AWS_PAGER=""
export REGION=ap-northeast-1
export CLUSTER_NAME=o11y-cluster
saws eks update-kubeconfig --name $CLUSTER --region $REGION
eksctl utils write-kubeconfig --name $CLUSTER_NAME
eksctl utils associate-iam-oidc-provider --approve --cluster $CLUSTER_NAME
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
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/${CLUSTER_NAME}-LBControllerRole
EOF
kubectl apply -f service-account.yaml
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
kubectl get pods -n kube-system | grep aws-load-balancer-controller
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update



cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations: { storageclass.kubernetes.io/is-default-class: "true" }
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters: { type: gp3 }
EOF
kubectl create namespace o11y
kubectl create namespace monitoring




cat <<EOF >> loki-values.yaml
deploymentMode: SingleBinary
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
  limits_config:
    allow_structured_metadata: true
    volume_enabled: true
    retention_period: 168h
  pattern_ingester:
    enabled: false
  ingester:
    chunk_encoding: snappy
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    storageClass: gp3
    size: 10Gi
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0
chunksCache:
  enabled: false
resultsCache:
  enabled: false
lokiCanary:
  enabled: false
test:
  enabled: false
gateway:
  enabled: false
monitoring:
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
  serviceMonitor:
    enabled: false
EOF

helm upgrade --install o11y-loki grafana/loki -n monitoring -f ./loki-values.yaml --wait --timeout 10m


cat <<EOF >> otel-values.yaml
mode: daemonset
fullnameOverride: o11y-otel
image:
  repository: otel/opentelemetry-collector-contrib
command:
  name: otelcol-contrib
presets:
  logsCollection:
    enabled: true
    includeCollectorLogs: false
  kubernetesAttributes:
    enabled: true
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
config:
  receivers:
    filelog:
      include:
        - /var/log/pods/*/*/*.log
  processors:
    k8sattributes:
      auth_type: serviceAccount
      passthrough: false
      extract:
        metadata:
          - k8s.namespace.name
          - k8s.pod.name
          - k8s.pod.uid
          - k8s.node.name
          - k8s.container.name
      pod_association:
        - sources:
            - from: resource_attribute
              name: k8s.pod.uid
  exporters:
    otlphttp/loki:
      endpoint: http://o11y-loki.monitoring.svc.cluster.local:3100/otlp
  service:
    pipelines:
      logs:
        receivers: [filelog]
        processors: [memory_limiter, k8sattributes, batch]
        exporters: [otlphttp/loki]
EOF
helm upgrade --install o11y-otel open-telemetry/opentelemetry-collector -n monitoring -f ./otel-values.yaml --wait
helm get manifest o11y-otel -n monitoring > otel-rendered.yaml
helm uninstall o11y-otel -n monitoring
sed 's/o11y-otel-agent/o11y-otel/g' otel-rendered.yaml | kubectl apply -f -






cat <<EOF > grafana-values.yaml
fullnameOverride: o11y-grafana
replicas: 1
adminUser: skills${BNUM}
adminPassword: "GoodJob!Skills${BNUM}^^"
persistence:
  enabled: false
service:
  type: ClusterIP
  port: 80
  targetPort: 3000
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        uid: loki
        access: proxy
        url: http://o11y-loki.monitoring.svc.cluster.local:3100
        isDefault: true
        jsonData:
          timeout: 60
          maxLines: 1000
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: default
        orgId: 1
        folder: ""
        type: file
        disableDeletion: false
        editable: true
        allowUiUpdates: true
        options:
          path: /var/lib/grafana/dashboards/default
dashboards:
  default:
    log-overview:
      json: |
        {
          "annotations": {"list": []},
          "editable": true,
          "graphTooltip": 0,
          "schemaVersion": 39,
          "tags": [],
          "time": {"from": "now-1h", "to": "now"},
          "refresh": "10s",
          "title": "Log Overview",
          "uid": "log-overview",
          "panels": [
            {
              "id": 1,
              "title": "Log Count Over Time",
              "type": "barchart",
              "datasource": {"type": "loki", "uid": "loki"},
              "gridPos": {"h": 9, "w": 12, "x": 0, "y": 0},
              "fieldConfig": {
                "defaults": {
                  "custom": {"lineWidth": 1, "fillOpacity": 80, "stacking": {"mode": "normal"}},
                  "color": {"mode": "palette-classic"}
                },
                "overrides": [
                  {"matcher": {"id": "byName", "options": "INFO"}, "properties": [{"id": "color", "value": {"fixedColor": "green", "mode": "fixed"}}]},
                  {"matcher": {"id": "byName", "options": "WARN"}, "properties": [{"id": "color", "value": {"fixedColor": "yellow", "mode": "fixed"}}]},
                  {"matcher": {"id": "byName", "options": "ERROR"}, "properties": [{"id": "color", "value": {"fixedColor": "red", "mode": "fixed"}}]}
                ]
              },
              "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "xField": "Time", "stacking": "normal"},
              "targets": [
                {
                  "datasource": {"type": "loki", "uid": "loki"},
                  "expr": "sum by (level) (count_over_time({k8s_namespace_name=\"o11y\"} | json | __error__=\"\" [1m]))",
                  "legendFormat": "{{level}}",
                  "queryType": "range",
                  "refId": "A"
                }
              ]
            },
            {
              "id": 2,
              "title": "Log Level Distribution",
              "type": "piechart",
              "datasource": {"type": "loki", "uid": "loki"},
              "gridPos": {"h": 9, "w": 12, "x": 12, "y": 0},
              "fieldConfig": {
                "defaults": {
                  "displayName": "\${__field.labels.level}"
                },
                "overrides": [
                  {"matcher": {"id": "byName", "options": "INFO"}, "properties": [{"id": "color", "value": {"fixedColor": "green", "mode": "fixed"}}]},
                  {"matcher": {"id": "byName", "options": "WARN"}, "properties": [{"id": "color", "value": {"fixedColor": "yellow", "mode": "fixed"}}]},
                  {"matcher": {"id": "byName", "options": "ERROR"}, "properties": [{"id": "color", "value": {"fixedColor": "red", "mode": "fixed"}}]}
                ]
              },
              "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": true}, "pieType": "pie", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}},
              "targets": [
                {
                  "datasource": {"type": "loki", "uid": "loki"},
                  "expr": "sum by (level) (count_over_time({k8s_namespace_name=\"o11y\"} | json | __error__=\"\" [1h]))",
                  "legendFormat": "{{level}}",
                  "queryType": "range",
                  "refId": "A"
                }
              ]
            },
            {
              "id": 3,
              "title": "Recent Logs",
              "type": "logs",
              "datasource": {"type": "loki", "uid": "loki"},
              "gridPos": {"h": 11, "w": 24, "x": 0, "y": 9},
              "options": {"showTime": true, "showLabels": true, "showCommonLabels": false, "wrapLogMessage": false, "prettifyLogMessage": false, "enableLogDetails": true, "dedupStrategy": "none", "sortOrder": "Descending"},
              "targets": [
                {
                  "datasource": {"type": "loki", "uid": "loki"},
                  "expr": "{k8s_namespace_name=\"o11y\"} | json | __error__=\"\"",
                  "queryType": "range",
                  "refId": "A"
                }
              ]
            }
          ]
        }
EOF

helm upgrade --install o11y-grafana grafana/grafana -n monitoring -f ./grafana-values.yaml --wait






export REGION=ap-northeast-1
export ACCT=$(aws sts get-caller-identity --query Account --output text)
export IMG=$ACCT.dkr.ecr.$REGION.amazonaws.com/o11y-log-generator:v1
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: log-generator, namespace: o11y }
spec:
  replicas: 2
  selector: { matchLabels: { app: log-generator } }
  template:
    metadata: { labels: { app: log-generator } }
    spec:
      containers:
        - name: app
          image: $IMG
          ports: [{ containerPort: 8080 }]
          readinessProbe: { httpGet: { path: /healthz, port: 8080 } }
---
apiVersion: v1
kind: Service
metadata: { name: log-generator, namespace: o11y }
spec:
  selector: { app: log-generator }
  ports: [{ port: 8080, targetPort: 8080 }]
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: log-traffic, namespace: o11y }
spec:
  replicas: 1
  selector: { matchLabels: { app: log-traffic } }
  template:
    metadata: { labels: { app: log-traffic } }
    spec:
      containers:
        - name: gen
          image: curlimages/curl:8.11.1
          command: ["/bin/sh","-c","while true; do
            curl -s 'http://log-generator.o11y:8080/log?level=info&count=5' >/dev/null;
            curl -s 'http://log-generator.o11y:8080/log?level=warn&count=3' >/dev/null;
            curl -s 'http://log-generator.o11y:8080/log?level=error&count=2' >/dev/null;
            sleep 15; done"]
EOF


export REGION=ap-northeast-1
export CLUSTER=o11y-cluster
export VPC=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text)
export CLSG=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
PUB=$(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$VPC" "Name=tag:kubernetes.io/role/elb,Values=1" --query 'Subnets[].SubnetId' --output text)
ALBSG=$(aws ec2 create-security-group --region $REGION --group-name o11y-alb-sg --description "o11y alb" --vpc-id $VPC --query GroupId --output text)
aws ec2 authorize-security-group-ingress --region $REGION --group-id $ALBSG --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region $REGION --group-id $CLSG --protocol tcp --port 8080 --source-group $ALBSG
aws ec2 authorize-security-group-ingress --region $REGION --group-id $CLSG --protocol tcp --port 3000 --source-group $ALBSG
create_alb () {
  local TG ALB
  TG=$(aws elbv2 create-target-group --region $REGION --name $2 --protocol HTTP --port $3 \
    --vpc-id $VPC --target-type ip --health-check-path "$4" --matcher HttpCode=200 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  ALB=$(aws elbv2 create-load-balancer --region $REGION --name $1 --type application --scheme internet-facing \
    --subnets $PUB --security-groups $ALBSG --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  aws elbv2 create-listener --region $REGION --load-balancer-arn $ALB --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG >/dev/null
  echo "$TG"
}
APP_TG=$(create_alb o11y-app-alb o11y-app-tg 8080 /healthz)
GRF_TG=$(create_alb o11y-grafana-alb o11y-grafana-tg 3000 /api/health)
cat <<EOF | kubectl apply -f -
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata: { name: o11y-app-tgb, namespace: o11y }
spec:
  serviceRef: { name: log-generator, port: 8080 }
  targetGroupARN: $APP_TG
  targetType: ip
---
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata: { name: o11y-grafana-tgb, namespace: monitoring }
spec:
  serviceRef: { name: o11y-grafana, port: 80 }
  targetGroupARN: $GRF_TG
  targetType: ip
EOF

helm upgrade --install o11y-loki grafana/loki -n monitoring -f ./loki-values.yaml --wait --timeout 10m
