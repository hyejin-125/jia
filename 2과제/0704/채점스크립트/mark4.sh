#!/bin/bash

echo "Module 4 - EKS O11y"
export AWS_ACCESS_KEY_ID=""
export AWS_SECRET_ACCESS_KEY=""
rm -rf ~/.aws
aws sts get-caller-identity | jq .Account
echo "채점준비 끝! 채점 시작!"

echo "=== 4-1-A ==="
aws eks describe-cluster --name o11y-cluster --query 'cluster.[name, version, status]' --output text --region ap-northeast-1
aws eks describe-nodegroup --cluster-name o11y-cluster --nodegroup-name "$(aws eks list-nodegroups --cluster-name o11y-cluster --region ap-northeast-1 --query 'nodegroups[0]' --output text)" --query 'nodegroup.[instanceTypes[0], scalingConfig.minSize, scalingConfig.desiredSize, scalingConfig.maxSize]' --output text --region ap-northeast-1
aws eks update-kubeconfig --name o11y-cluster --region ap-northeast-1 > /dev/null 2>&1
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' | sort -u

echo "=== 4-2-A ==="

for n in o11y-app-alb o11y-grafana-alb; do
  aws elbv2 describe-load-balancers --names $n --query 'LoadBalancers[0].[State.Code, Type, Scheme]' --output text --region ap-northeast-1
done

for n in o11y-app-tg o11y-grafana-tg; do
  aws elbv2 describe-target-health --target-group-arn "$(aws elbv2 describe-target-groups --names $n --query 'TargetGroups[0].TargetGroupArn' --output text --region ap-northeast-1)" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text --region ap-northeast-1
done

echo "=== 4-3-A ==="
kubectl get deploy log-generator -n o11y -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas'
kubectl get ds o11y-otel -n monitoring -o custom-columns='NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady'
kubectl get svc o11y-loki -n monitoring -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,PORT:.spec.ports[0].port' 
kubectl get deploy o11y-grafana -n monitoring -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas' 

echo "=== 4-4-A ==="
ALB=$(aws elbv2 describe-load-balancers --names o11y-app-alb --query 'LoadBalancers[0].DNSName' --output text --region ap-northeast-1)
curl -s "http://$ALB/healthz"; echo
curl -s "http://$ALB/log?level=error&count=3" | head -1 | jq -r '.level, .generated'

echo "=== 4-5-A ==="
echo "manual marking"
# RESP=$(curl -s "http://$(aws elbv2 describe-load-balancers --names o11y-app-alb --query 'LoadBalancers[0].DNSName' --output text --region ap-northeast-1)/log?level=error&count=3")
# echo "$RESP" | jq -c .

# kubectl port-forward -n monitoring svc/o11y-loki 3100:3100 > /dev/null 2>&1 &
# PF=$!
# sleep 60
# curl -s -G http://localhost:3100/loki/api/v1/query_range --data-urlencode "query={k8s_namespace_name=\"o11y\"} |~ \"$PATTERN\"" --data-urlencode "start=$(($(date +%s) - 180))000000000" --data-urlencode "end=$(date +%s)000000000" --data-urlencode 'limit=20' | jq -r '.data.result[].values[][1]'
# kill $PF 2>/dev/null


echo "=== 4-6-A ==="
echo 'manual marking'