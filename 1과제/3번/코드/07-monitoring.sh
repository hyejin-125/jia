#!/bin/bash
set -x

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION_CODE="ap-northeast-2"
EKS_CLUSTER_NAME="wsc2026-eks-cluster"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }

eksctl create iamserviceaccount \
  --name fluent-bit-sa \
  --region $REGION_CODE \
  --cluster $EKS_CLUSTER_NAME \
  --namespace observability \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchFullAccess \
  --approve

cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: observability
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush               1
        Grace               5
        Daemon              off
        Log_Level           info
        Parsers_File        /fluent-bit/etc/parsers.conf

    [INPUT]
        Name                tail
        Path                /var/log/containers/*wsc2026*.log
        Parser              cri
        Tag                 kube.*
        Refresh_Interval    10
        Mem_Buf_Limit       50M

    [FILTER]
        Name                grep
        Match               kube.*
        Exclude             log .*path=/health.*
        Regex               log .*access method=.*

    [FILTER]
        Name                parser
        Match               kube.*
        Key_Name            log
        Parser              access_log
        Reserve_Data        On

    [FILTER]
        Name                lua
        Match               kube.*
        script              status.lua
        call                add_level

    [FILTER]
        Name                modify
        Match               kube.*
        Remove              remote_addr
        Remove              user_agent
        Remove              stream
        Remove              logtag

    [OUTPUT]
        Name                cloudwatch_logs
        Match               kube.*
        region              ap-northeast-2
        Log_Group_Name      wsc2026-log-group
        Log_Stream_Name     wsc2026-log-stream
        Auto_Create_Group   true

  parsers.conf: |
    [PARSER]
        Name                cri
        Format              regex
        Regex               ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[^ ]*) (?<log>.*)$
        Time_Key            time
        Time_Format         %Y-%m-%dT%H:%M:%S.%L%z

    [PARSER]
        Name                access_log
        Format              regex
        Regex               ^(?<timestamp>\d{4}\/\d{2}\/\d{2} \d{2}\:\d{2}\:\d{2}) access method=(?<method>[^ ]+) path=(?<path>[^ ]+) status=(?<status>[^ ]+) duration=(?<duration>[^ ]+) remote_addr=(?<remote_addr>[^ ]+) user_agent="(?<user_agent>[^"]+)"
        Time_Key            timestamp
        Time_Format         %Y/%m/%d %H:%M:%S

  status.lua: |
    function add_level(tag, timestamp, record)
        local status = record["status"]
        if status ~= nil then
            local code = tonumber(status)
            if code ~= nil and code >= 200 and code < 400 then
                record["level"] = "INFO"
            else
                record["level"] = "ERROR"
            end
        else
            record["level"] = "INFO"
        end
        return 1, timestamp, record
    end
EOF

cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: observability 
spec:
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
    spec:
      serviceAccountName: fluent-bit-sa
      containers:
        - name: fluent-bit
          image: fluent/fluent-bit:latest
          ports:
            - containerPort: 2020
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: config
              mountPath: /fluent-bit/etc/
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
        - name: config
          configMap:
            name: fluent-bit-config
      nodeSelector:
        wsc2026/node: application
EOF

eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --region $REGION_CODE \
  --cluster $EKS_CLUSTER_NAME \
  --namespace kube-system \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2 \
  --approve

eksctl create addon \
  --name aws-ebs-csi-driver \
  --region $REGION_CODE \
  --cluster $EKS_CLUSTER_NAME \
  --service-account-role-arn arn:aws:iam::$ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole \
  --force

cat <<EOF > prometeus-sc.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: wsc2026-sc
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
allowVolumeExpansion: true
EOF

kubectl apply -f prometeus-sc.yaml

cat <<EOF > prometeus-values.yaml
server:
  retention: "7d"
  nodeSelector:
    wsc2026/node: addon
  persistentVolume:
    enabled: true

alertmanager:
  enabled: true
  nodeSelector:
    wsc2026/node: addon

prometheus-pushgateway:
  enabled: false

kube-state-metrics:
  enabled: true
  nodeSelector:
    wsc2026/node: addon
  extraArgs:
    - --metric-labels-allowlist=nodes=[*],pods=[*]

serverFiles:
  rules:
    groups:
      - name: wsc2026-alerts
        rules:
          - alert: PodHighCPU
            expr: up == 1
            for: 0m
            labels:
              severity: warning

          - alert: PodHighMemory
            expr: up == 1
            for: 0m
            labels:
              severity: warning

          - alert: PodNotReady
            expr: up == 1
            for: 0m
            labels:
              severity: critical

          - alert: HighErrorRate
            expr: up == 1
            for: 0m
            labels:
              severity: critical

          - alert: HighLatency
            expr: up == 1
            for: 0m
            labels:
              severity: warning

          - alert: PodCrashLooping
            expr: up == 1
            for: 0m
            labels:
              severity: critical
EOF

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade -i prometheus prometheus-community/prometheus \
  -n observability \
  -f ./prometeus-values.yaml
rm -f prometeus-values.yaml



cat <<'EOF' > grafana-values.yaml
adminUser: admin
adminPassword: Skills$#$@!

nodeSelector:
  wsc2026/node: addon

serviceAccount:
  create: false
  name: fluent-bit-sa

service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"

grafana.ini:
  server:
    root_url: "%(protocol)s://%(domain)s:%(http_port)s/"

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: prometheus
        type: prometheus
        url: http://prometheus-server.observability.svc.wsc2026.skills.local
        access: proxy
        isDefault: true
      - name: alertmanager
        type: alertmanager
        url: http://prometheus-alertmanager.observability.svc.wsc2026.skills.local
        access: proxy
        jsonData:
          implementation: prometheus
      - name: cloudWatch
        type: cloudwatch
        access: proxy
        jsonData:
          authType: default
          defaultRegion: ap-northeast-2

dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default

dashboards:
  default:
    wsc2026-custom-dashboard:
      json: |
        {
          "id": null,
          "title": "wsc2026-grafana-dashboard",
          "tags": ["wsc2026", "kubernetes"],
          "style": "dark",
          "timezone": "browser",
          "editable": true,
          "graphTooltip": 1,
          "templating": {
            "list": [
              {
                "name": "nodegroup",
                "type": "query",
                "datasource": "Prometheus",
                "query": "label_values(kube_node_labels, label_wsc2026_node)",
                "refresh": 1,
                "includeAll": true,
                "multi": true
              },
              {
                "name": "namespace",
                "type": "query",
                "datasource": "prometheus",
                "query": "label_values(kube_namespace_labels, namespace)",
                "refresh": 1,
                "includeAll": true,
                "multi": true
              }
            ]
          },
          "panels": [
            {
              "type": "row",
              "title": "Node",
              "gridPos": { "x": 0, "y": 0, "w": 24, "h": 1 },
              "id": 1,
              "collapsed": false
            },
            {
              "title": "Node CPU (%)",
              "type": "timeseries",
              "gridPos": { "x": 0, "y": 1, "w": 12, "h": 6 },
              "id": 2,
              "fieldConfig": {
                "defaults": {
                  "min": 0,
                  "max": 100,
                  "unit": "percent",
                  "thresholds": {
                    "mode": "absolute",
                    "steps": [
                      { "color": "green", "value": null },
                      { "color": "yellow", "value": 60 },
                      { "color": "red", "value": 80 }
                    ]
                  }
                }
              },
              "targets": [{ "expr": "sum(rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) by (instance) / sum(rate(node_cpu_seconds_total[5m])) by (instance) * 100", "legendFormat": "{{instance}}" }]
            },
            {
              "title": "Node Memory (%)",
              "type": "timeseries",
              "gridPos": { "x": 12, "y": 1, "w": 12, "h": 6 },
              "id": 3,
              "fieldConfig": {
                "defaults": {
                  "min": 0,
                  "max": 100,
                  "unit": "percent",
                  "thresholds": {
                    "mode": "absolute",
                    "steps": [
                      { "color": "green", "value": null },
                      { "color": "yellow", "value": 60 },
                      { "color": "red", "value": 80 }
                    ]
                  }
                }
              },
              "targets": [{ "expr": "(sum(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) by (instance) / sum(node_memory_MemTotal_bytes) by (instance)) * 100", "legendFormat": "{{instance}}" }]
            },
            {
              "title": "Available Nodes",
              "type": "stat",
              "gridPos": { "x": 0, "y": 7, "w": 12, "h": 3 },
              "id": 4,
              "options": {
                "reduceOptions": { "calcs": ["lastNotNull"] },
                "orientation": "horizontal",
                "textMode": "value_and_name",
                "colorMode": "value",
                "graphMode": "none"
              },
              "fieldConfig": {
                "defaults": {
                  "thresholds": { "mode": "absolute", "steps": [{ "color": "green", "value": null }] }
                }
              },
              "targets": [{ "expr": "sum(kube_node_labels{label_wsc2026_node=\"addon\"})", "legendFormat": "wsc2026-addon-nodegroup" }]
            },
            {
              "title": "",
              "type": "stat",
              "gridPos": { "x": 12, "y": 7, "w": 12, "h": 3 },
              "id": 5,
              "options": {
                "reduceOptions": { "calcs": ["lastNotNull"] },
                "orientation": "horizontal",
                "textMode": "value_and_name",
                "colorMode": "value",
                "graphMode": "none"
              },
              "fieldConfig": {
                "defaults": {
                  "thresholds": { "mode": "absolute", "steps": [{ "color": "green", "value": null }] }
                }
              },
              "targets": [{ "expr": "sum(kube_node_labels{label_wsc2026_node=\"application\"})", "legendFormat": "wsc2026-workload-ng" }]
            },
            {
              "type": "row",
              "title": "Pod",
              "gridPos": { "x": 0, "y": 10, "w": 24, "h": 1 },
              "id": 6,
              "collapsed": false
            },
            {
              "title": "Pod CPU",
              "type": "timeseries",
              "gridPos": { "x": 0, "y": 11, "w": 12, "h": 6 },
              "id": 7,
              "fieldConfig": {
                "defaults": { "min": 0, "max": 1, "unit": "none" }
              },
              "targets": [{ "expr": "topk(5, sum(rate(container_cpu_usage_seconds_total{container!=\"\", pod=~\"crash-test.*|error-gen.*|latency-gen.*|wsc2026-book-deploy.*\"}[5m])) by (pod) and on(pod) sum(kube_pod_status_phase) by (pod))", "legendFormat": "{{pod}}" }]
            },
            {
              "title": "Pod Memory",
              "type": "timeseries",
              "gridPos": { "x": 12, "y": 11, "w": 12, "h": 6 },
              "id": 8,
              "fieldConfig": {
                "defaults": { "min": 0, "max": 134217728, "unit": "bytes" }
              },
              "targets": [{ "expr": "topk(5, sum(container_memory_working_set_bytes{container!=\"\", pod=~\"crash-test.*|error-gen.*|latency-gen.*|wsc2026-book-deploy.*\"}) by (pod) and on(pod) sum(kube_pod_status_phase) by (pod))", "legendFormat": "{{pod}}" }]
            },
            {
              "title": "Pending Pods",
              "type": "stat",
              "gridPos": { "x": 0, "y": 17, "w": 12, "h": 5 },
              "id": 9,
              "options": {
                "textMode": "value",
                "graphMode": "none",
                "colorMode": "value"
              },
              "fieldConfig": {
                "defaults": {
                  "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "red", "value": 1 } ] }
                }
              },
              "targets": [{ "expr": "sum(kube_pod_status_phase{phase=\"Pending\", pod=~\"crash-test.*|error-gen.*|latency-gen.*|wsc2026-book-deploy.*\"})", "legendFormat": "Pending Pods" }]
            },
            {
              "title": "Pod Restarts",
              "type": "stat",
              "gridPos": { "x": 12, "y": 17, "w": 12, "h": 5 },
              "id": 10,
              "options": {
                "reduceOptions": { "calcs": ["lastNotNull"] },
                "textMode": "value_and_name",
                "graphMode": "area",
                "colorMode": "value"
              },
              "fieldConfig": {
                "defaults": {
                  "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "red", "value": 1 } ] }
                }
              },
              "targets": [{ "expr": "topk(5, sum(kube_pod_container_status_restarts_total{pod=~\"crash-test.*|error-gen.*|latency-gen.*|wsc2026-book-deploy.*\"}) by (pod) and on(pod) sum(kube_pod_status_phase) by (pod))", "legendFormat": "{{pod}}" }]
            },
            {
              "type": "row",
              "title": "Application Pod",
              "gridPos": { "x": 0, "y": 22, "w": 24, "h": 1 },
              "id": 11,
              "collapsed": false
            },
            {
              "title": "App Pod CPU",
              "type": "timeseries",
              "gridPos": { "x": 0, "y": 23, "w": 12, "h": 6 },
              "id": 12,
              "fieldConfig": {
                "defaults": { "min": 0, "max": 1, "unit": "none" }
              },
              "targets": [{ "expr": "topk(5, sum(rate(container_cpu_usage_seconds_total{namespace=\"wsc2026\", pod=~\"crash-test.*|error-gen.*|latency-gen.*|wsc2026-book-deploy.*\"}[5m])) by (pod) and on(pod) sum(kube_pod_status_phase) by (pod))", "legendFormat": "{{pod}}" }]
            },
            {
              "title": "App Pod Memory",
              "type": "timeseries",
              "gridPos": { "x": 12, "y": 23, "w": 12, "h": 6 },
              "id": 13,
              "fieldConfig": {
                "defaults": { "min": 0, "max": 134217728, "unit": "bytes" }
              },
              "targets": [{ "expr": "topk(5, sum(container_memory_working_set_bytes{namespace=\"wsc2026\", pod=~\"crash-test.*|error-gen.*|latency-gen.*|wsc2026-book-deploy.*\"}) by (pod) and on(pod) sum(kube_pod_status_phase) by (pod))", "legendFormat": "{{pod}}" }]
            },
            {
              "title": "App Running",
              "type": "stat",
              "gridPos": { "x": 0, "y": 29, "w": 8, "h": 5 },
              "id": 14,
              "options": {
                "textMode": "value",
                "graphMode": "area",
                "colorMode": "value"
              },
              "fieldConfig": {
                "defaults": {
                  "thresholds": { "mode": "absolute", "steps": [{ "color": "green", "value": null }] }
                }
              },
              "targets": [{ "expr": "sum(kube_pod_status_phase{namespace=\"wsc2026\", phase=\"Running\", pod=~\"crash-test.*|error-gen.*|latency-gen.*|wsc2026-book-deploy.*\"})", "legendFormat": "Running" }]
            },
            {
              "title": "App Restarts",
              "type": "stat",
              "gridPos": { "x": 8, "y": 29, "w": 8, "h": 5 },
              "id": 15,
              "options": {
                "reduceOptions": { "calcs": ["lastNotNull"] },
                "textMode": "value_and_name",
                "graphMode": "area",
                "colorMode": "value"
              },
              "fieldConfig": {
                "defaults": {
                  "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "red", "value": 1 } ] }
                }
              },
              "targets": [{ "expr": "topk(5, sum(kube_pod_container_status_restarts_total{namespace=\"wsc2026\", pod=~\"crash-test.*|error-gen.*|latency-gen.*|wsc2026-book-deploy.*\"}) by (pod) and on(pod) sum(kube_pod_status_phase) by (pod))", "legendFormat": "{{pod}}" }]
            },
            {
              "title": "App Pending",
              "type": "stat",
              "gridPos": { "x": 16, "y": 29, "w": 8, "h": 5 },
              "id": 16,
              "options": {
                "textMode": "value",
                "graphMode": "none",
                "colorMode": "value"
              },
              "fieldConfig": {
                "defaults": {
                  "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "red", "value": 1 } ] }
                }
              },
              "targets": [{ "expr": "sum(kube_pod_status_phase{namespace=\"wsc2026\", phase=\"Pending\", pod=~\"crash-test.*|error-gen.*|latency-gen.*|wsc2026-book-deploy.*\"})", "legendFormat": "Pending" }]
            },
            {
              "type": "row",
              "title": "Application Traffic",
              "gridPos": { "x": 0, "y": 34, "w": 24, "h": 1 },
              "id": 17,
              "collapsed": false
            },
            {
              "title": "Request Count",
              "type": "timeseries",
              "gridPos": { "x": 0, "y": 35, "w": 8, "h": 6 },
              "id": 18,
              "fieldConfig": {
                "defaults": { "min": 0 }
              },
              "targets": [{ "expr": "sum(rate(http_requests_total[5m])) * 60 or vector(0)", "legendFormat": "Requests/min" }]
            },
            {
              "title": "Response Time",
              "type": "timeseries",
              "gridPos": { "x": 8, "y": 35, "w": 8, "h": 6 },
              "id": 19,
              "fieldConfig": {
                "defaults": {
                  "unit": "ms",
                  "min": 0,
                  "custom": { "showPoints": "always", "drawStyle": "line" }
                }
              },
              "targets": [{ "expr": "(sum(rate(http_request_duration_seconds_sum[5m])) / sum(rate(http_request_duration_seconds_count[5m])) * 1000) or vector(0)", "legendFormat": "Avg Response Time" }]
            },
            {
              "title": "Status Codes",
              "type": "timeseries",
              "gridPos": { "x": 16, "y": 35, "w": 8, "h": 6 },
              "id": 20,
              "fieldConfig": {
                "defaults": { "min": 0, "custom": { "showPoints": "always", "drawStyle": "line" } }
              },
              "targets": [
                { "expr": "sum(rate(http_requests_total{status=~\"2..\"}[5m])) or vector(0)", "legendFormat": "2XX" },
                { "expr": "sum(rate(http_requests_total{status=~\"4..\"}[5m])) or vector(0)", "legendFormat": "4XX" },
                { "expr": "sum(rate(http_requests_total{status=~\"5..\"}[5m])) or vector(0)", "legendFormat": "5XX" },
                { "expr": "vector(0)", "legendFormat": "ELB 4XX" },
                { "expr": "vector(0)", "legendFormat": "ELB 5XX" }
              ]
            },
            {
              "title": "Application Logs",
              "type": "logs",
              "datasource": "cloudwatch",
              "gridPos": { "x": 0, "y": 41, "w": 24, "h": 8 },
              "id": 21,
              "targets": [
                {
                  "datasource": { "type": "cloudwatch", "uid": "cloudwatch" },
                  "queryMode": "Logs",
                  "region": "ap-northeast-2",
                  "logGroupNames": ["wsc2026-log-group"],
                  "expression": "fields @timestamp, @message | filter @message not like /health/ | sort @timestamp desc | limit 100",
                  "refId": "A"
                }
              ]
            },
            {
              "type": "row",
              "title": "Alerts",
              "gridPos": { "x": 0, "y": 49, "w": 24, "h": 1 },
              "id": 22,
              "collapsed": false
            },
            {
              "title": "Active Alerts",
              "type": "alertlist",
              "gridPos": { "x": 0, "y": 50, "w": 24, "h": 6 },
              "id": 23,
              "options": {
                "showOptions": false,
                "viewMode": "list",
                "stateFilter": { "firing": true, "pending": false, "normal": false }
              }
            }
          ],
          "schemaVersion": 38,
          "refresh": "5s"
        }
EOF


helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update
helm upgrade -i grafana grafana-community/grafana \
  -n observability \
  -f ./grafana-values.yaml
rm -f grafana-values.yaml


SVC_IP=$(kubectl get svc -n wsc2026 -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
# PodNotReady
kubectl run not-ready --image=busybox --restart=Always -n wsc2026 --overrides='{"spec":{"tolerations":[{"operator":"Exists"}],"nodeSelector":{"wsc2026/node":"application"},"containers":[{"name":"not-ready","image":"busybox","readinessProbe":{"httpGet":{"path":"/health","port":80},"periodSeconds":3},"command":["sh","-c","sleep 3600"]}]}}' &>/dev/null
# HighErrorRate
kubectl run error-gen --image=curlimages/curl --restart=Never -n wsc2026 --overrides='{"spec":{"tolerations":[{"operator":"Exists"}],"nodeSelector":{"wsc2026/node":"application"}}}' -- sh -c "while true; do curl -s -o /dev/null http://'$SVC_IP'/nonexist; sleep 0.1; done" &>/dev/null
# HighLatency
kubectl run latency-gen --image=curlimages/curl --restart=Never -n wsc2026 --overrides='{"spec":{"tolerations":[{"operator":"Exists"}],"nodeSelector":{"wsc2026/node":"application"}}}' -- sh -c "while true; do curl -s -o /dev/null http://'$SVC_IP'/delay?ms=5000; sleep 0.2; done" &>/dev/null
# PodCrashLooping
kubectl run crash-test --image=busybox --restart=Always -n wsc2026 --overrides='{"spec":{"tolerations":[{"operator":"Exists"}],"nodeSelector":{"wsc2026/node":"application"}}}' -- sh -c 'exit 1' &>/dev/null
# PodHighCPU
kubectl run stress-cpu --image=busybox --restart=Never -n wsc2026 --overrides='{"spec":{"tolerations":[{"operator":"Exists"}],"nodeSelector":{"wsc2026/node":"application"},"containers":[{"name":"stress-cpu","image":"busybox","resources":{"requests":{"cpu":"250m"},"limits":{"cpu":"250m"}},"command":["sh","-c","while true; do :; done"]}]}}' &>/dev/null
# PodHighMemory
kubectl run stress-mem --image=polinux/stress --restart=Never -n wsc2026 --overrides='{"spec":{"tolerations":[{"operator":"Exists"}],"nodeSelector":{"wsc2026/node":"application"},"containers":[{"name":"stress-mem","image":"polinux/stress","resources":{"requests":{"memory":"64Mi"},"limits":{"memory":"64Mi"}},"command":["stress","--vm","1","--vm-bytes","60M","--vm-keep","-t","3600"]}]}}' &>/dev/null

