#!/usr/bin/env bash
set -u
export AWS_PAGER=""

OUT_TXT="asgmt2_module1_check_result.txt"
exec > >(tee "$OUT_TXT") 2>&1

for CMD in aws jq curl; do
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $CMD" >&2
    exit 2
  fi
done

echo "== 제2과제 1모듈 DocumentDB based NoSQL Application 채점 출력 =="
echo

echo "[1-1] DocumentDB Cluster 및 Instance 구성 (1.5점)"
aws docdb describe-db-clusters --region ap-northeast-2 --db-cluster-identifier skills-nosql-docdb-cluster --query 'DBClusters[0].{Cluster:DBClusterIdentifier,Status:Status,Engine:Engine,Version:EngineVersion,Encrypted:StorageEncrypted,KmsKeyId:KmsKeyId,BackupRetention:BackupRetentionPeriod,Endpoint:Endpoint,Port:Port}' --output table
aws docdb describe-db-instances --region ap-northeast-2 --db-instance-identifier skills-nosql-docdb-instance-1 --query 'DBInstances[0].{Instance:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass,Engine:Engine,Cluster:DBClusterIdentifier,AZ:AvailabilityZone}' --output table
aws kms describe-key --region ap-northeast-2 --key-id alias/skills-nosql-docdb --query 'KeyMetadata.{Arn:Arn,Enabled:Enabled,KeyManager:KeyManager,KeyUsage:KeyUsage}' --output table

echo
echo "[1-2] Secret 및 Client EC2 구성 (1.5점)"
aws secretsmanager describe-secret --region ap-northeast-2 --secret-id skills-nosql-docdb-secret --query '{Name:Name,ARN:ARN,KmsKeyId:KmsKeyId}' --output table
aws secretsmanager get-secret-value --region ap-northeast-2 --secret-id skills-nosql-docdb-secret --query SecretString --output text | jq -r '{username, host, password_set:(.password != null and .password != "")}'
aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=skills-nosql-client-ec2 Name=instance-state-name,Values=running --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`].Value|[0],InstanceId:InstanceId,State:State.Name,Type:InstanceType,PublicIp:PublicIpAddress}' --output table

CLIENT_IP=$(aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=skills-nosql-client-ec2 Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || true)
echo "CLIENT_IP=${CLIENT_IP}"

echo
echo "[1-3] Client Application 및 데이터 적재 상태 (1.5점)"
if [ -n "$CLIENT_IP" ] && [ "$CLIENT_IP" != "None" ]; then
  curl -s -m 10 "http://${CLIENT_IP}:8080/health"; echo
  curl -s -m 10 "http://${CLIENT_IP}:8080/v1/admin/summary"; echo
else
  echo "Client EC2 Public IP 식별 실패"
fi

echo
echo "[1-4] DocumentDB Index 및 TTL 구성 (1.5점)"
if [ -n "$CLIENT_IP" ] && [ "$CLIENT_IP" != "None" ]; then
  curl -s -m 10 "http://${CLIENT_IP}:8080/v1/admin/indexes"; echo
else
  echo "Client EC2 Public IP 식별 실패"
fi

echo
echo "[1-5] NoSQL 조회 기능 검증 (1.5점)"
if [ -n "$CLIENT_IP" ] && [ "$CLIENT_IP" != "None" ]; then
  curl -s -m 10 "http://${CLIENT_IP}:8080/v1/orders/O-1001"; echo
  curl -s -m 10 "http://${CLIENT_IP}:8080/v1/customers/C001/orders"; echo
  curl -s -m 10 "http://${CLIENT_IP}:8080/v1/orders/pending?from=2026-06-01T00:00:00Z&to=2026-06-08T00:00:00Z"; echo
  curl -s -m 10 "http://${CLIENT_IP}:8080/v1/products/low-stock?warehouseId=W-A"; echo
else
  echo "Client EC2 Public IP 식별 실패"
fi

echo
echo "Result file: ${OUT_TXT}"
