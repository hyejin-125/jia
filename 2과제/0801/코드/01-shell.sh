#!/bin/bash
set -x

rm -rf ~/.aws
euo pipefail
export AWS_PAGER=""
REGION="ap-northeast-2"
VPC_NAME="skills-nosql-vpc"
VPC_CIDR="10.50.0.0/16"
PUBLIC_CIDRS=("10.50.1.0/24" "10.50.2.0/24")
PRIVATE_CIDRS=("10.50.11.0/24" "10.50.12.0/24")
KMS_ALIAS="alias/skills-nosql-docdb"
CLUSTER_ID="skills-nosql-docdb-cluster"
INSTANCE_ID="skills-nosql-docdb-instance-1"
DB_SUBNET_GROUP="skills-nosql-docdb-subnet-group"
SECRET_NAME="skills-nosql-docdb-secret"
DB_USERNAME="skills"
CLIENT_NAME="skills-nosql-client-ec2"
CLIENT_ROLE="skills-nosql-client-role"
CLIENT_PROFILE="skills-nosql-client-profile"
CLIENT_SG_NAME="skills-nosql-client-sg"
DOCDB_SG_NAME="skills-nosql-docdb-sg"
RESET_DOCDB_PASSWORD="${RESET_DOCDB_PASSWORD:-false}"
RECREATE_CLIENT_EC2="${RECREATE_CLIENT_EC2:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCDB_CLIENT="${SCRIPT_DIR}/docdb_client.py"
DATASET="${SCRIPT_DIR}/retail_dataset.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for cmd in aws jq curl gzip base64 openssl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: 필요한 명령을 찾을 수 없습니다: $cmd" >&2
    exit 2
  }
done
for file in "$DOCDB_CLIENT" "$DATASET"; do
  [[ -f "$file" ]] || {
    echo "ERROR: 파일이 없습니다: $file" >&2
    exit 2
  }
done

aws sts get-caller-identity >/dev/null
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
mapfile -t AZS < <(
  aws ec2 describe-availability-zones \
    --region "$REGION" \
    --filters Name=state,Values=available \
    --query 'AvailabilityZones[:2].ZoneName' \
    --output text | tr '\t' '\n'
)

tag_name() {
  aws ec2 create-tags --region "$REGION" --resources "$1" \
    --tags Key=Name,Value="$2" >/dev/null
}

KMS_KEY_ID="$(
  aws kms list-aliases --region "$REGION" \
    --query "Aliases[?AliasName=='${KMS_ALIAS}'].TargetKeyId | [0]" \
    --output text
)"
if [[ -z "$KMS_KEY_ID" || "$KMS_KEY_ID" == "None" ]]; then
  KMS_KEY_ID="$(
    aws kms create-key \
      --region "$REGION" \
      --description "KMS key for skills-nosql-docdb" \
      --tags TagKey=Name,TagValue=skills-nosql-docdb \
      --query KeyMetadata.KeyId \
      --output text
  )"
  aws kms create-alias --region "$REGION" \
    --alias-name "$KMS_ALIAS" --target-key-id "$KMS_KEY_ID"
fi
KMS_KEY_ARN="$(
  aws kms describe-key --region "$REGION" --key-id "$KMS_KEY_ID" \
    --query KeyMetadata.Arn --output text
)"

VPC_ID="$(
  aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=${VPC_NAME}" \
    --query 'Vpcs[0].VpcId' --output text
)"
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  VPC_ID="$(
    aws ec2 create-vpc --region "$REGION" --cidr-block "$VPC_CIDR" \
      --query Vpc.VpcId --output text
  )"
  aws ec2 wait vpc-available --region "$REGION" --vpc-ids "$VPC_ID"
  tag_name "$VPC_ID" "$VPC_NAME"
fi
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" \
  --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" \
  --enable-dns-hostnames '{"Value":true}'

IGW_ID="$(
  aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query 'InternetGateways[0].InternetGatewayId' --output text
)"
if [[ -z "$IGW_ID" || "$IGW_ID" == "None" ]]; then
  IGW_ID="$(
    aws ec2 create-internet-gateway --region "$REGION" \
      --query InternetGateway.InternetGatewayId --output text
  )"
  tag_name "$IGW_ID" "skills-nosql-igw"
  aws ec2 attach-internet-gateway --region "$REGION" \
    --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
fi

PUBLIC_SUBNETS=()
PRIVATE_SUBNETS=()
for i in 0 1; do
  n=$((i + 1))
  pub_name="skills-nosql-public-${n}"
  pub_id="$(
    aws ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${pub_name}" \
      --query 'Subnets[0].SubnetId' --output text
  )"
  if [[ -z "$pub_id" || "$pub_id" == "None" ]]; then
    pub_id="$(
      aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
        --availability-zone "${AZS[$i]}" --cidr-block "${PUBLIC_CIDRS[$i]}" \
        --query Subnet.SubnetId --output text
    )"
    tag_name "$pub_id" "$pub_name"
  fi
  aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$pub_id" \
    --map-public-ip-on-launch
  PUBLIC_SUBNETS+=("$pub_id")

  priv_name="skills-nosql-private-${n}"
  priv_id="$(
    aws ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${priv_name}" \
      --query 'Subnets[0].SubnetId' --output text
  )"
  if [[ -z "$priv_id" || "$priv_id" == "None" ]]; then
    priv_id="$(
      aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
        --availability-zone "${AZS[$i]}" --cidr-block "${PRIVATE_CIDRS[$i]}" \
        --query Subnet.SubnetId --output text
    )"
    tag_name "$priv_id" "$priv_name"
  fi
  PRIVATE_SUBNETS+=("$priv_id")
done

PUBLIC_RT="$(
  aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=skills-nosql-public-rt" \
    --query 'RouteTables[0].RouteTableId' --output text
)"
if [[ -z "$PUBLIC_RT" || "$PUBLIC_RT" == "None" ]]; then
  PUBLIC_RT="$(
    aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
      --query RouteTable.RouteTableId --output text
  )"
  tag_name "$PUBLIC_RT" "skills-nosql-public-rt"
fi
aws ec2 create-route --region "$REGION" --route-table-id "$PUBLIC_RT" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null 2>&1 ||
aws ec2 replace-route --region "$REGION" --route-table-id "$PUBLIC_RT" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
for subnet_id in "${PUBLIC_SUBNETS[@]}"; do
  association="$(
    aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=association.subnet-id,Values=${subnet_id}" \
      --query 'RouteTables[0].RouteTableId' --output text
  )"
  if [[ -z "$association" || "$association" == "None" ]]; then
    aws ec2 associate-route-table --region "$REGION" \
      --route-table-id "$PUBLIC_RT" --subnet-id "$subnet_id" >/dev/null
  fi
done

PRIVATE_RT="$(
  aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=skills-nosql-private-rt" \
    --query 'RouteTables[0].RouteTableId' --output text
)"
if [[ -z "$PRIVATE_RT" || "$PRIVATE_RT" == "None" ]]; then
  PRIVATE_RT="$(
    aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
      --query RouteTable.RouteTableId --output text
  )"
  tag_name "$PRIVATE_RT" "skills-nosql-private-rt"
fi
for subnet_id in "${PRIVATE_SUBNETS[@]}"; do
  association="$(
    aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=association.subnet-id,Values=${subnet_id}" \
      --query 'RouteTables[0].RouteTableId' --output text
  )"
  if [[ -z "$association" || "$association" == "None" ]]; then
    aws ec2 associate-route-table --region "$REGION" \
      --route-table-id "$PRIVATE_RT" --subnet-id "$subnet_id" >/dev/null
  fi
done

CLIENT_SG_ID="$(
  aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${CLIENT_SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text
)"
if [[ -z "$CLIENT_SG_ID" || "$CLIENT_SG_ID" == "None" ]]; then
  CLIENT_SG_ID="$(
    aws ec2 create-security-group --region "$REGION" \
      --group-name "$CLIENT_SG_NAME" \
      --description "Public HTTP access to DocumentDB client" \
      --vpc-id "$VPC_ID" --query GroupId --output text
  )"
  tag_name "$CLIENT_SG_ID" "$CLIENT_SG_NAME"
fi
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$CLIENT_SG_ID" --protocol tcp --port 8080 \
  --cidr 0.0.0.0/0 >/dev/null 2>&1 || true

DOCDB_SG_ID="$(
  aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${DOCDB_SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text
)"
if [[ -z "$DOCDB_SG_ID" || "$DOCDB_SG_ID" == "None" ]]; then
  DOCDB_SG_ID="$(
    aws ec2 create-security-group --region "$REGION" \
      --group-name "$DOCDB_SG_NAME" \
      --description "DocumentDB access only from client security group" \
      --vpc-id "$VPC_ID" --query GroupId --output text
  )"
  tag_name "$DOCDB_SG_ID" "$DOCDB_SG_NAME"
fi
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$DOCDB_SG_ID" --protocol tcp --port 27017 \
  --source-group "$CLIENT_SG_ID" >/dev/null 2>&1 || true

if ! aws docdb describe-db-subnet-groups --region "$REGION" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  aws docdb create-db-subnet-group --region "$REGION" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Private subnets for skills DocumentDB" \
    --subnet-ids "${PRIVATE_SUBNETS[@]}" \
    --tags Key=Name,Value="$DB_SUBNET_GROUP" >/dev/null
fi

SECRET_EXISTS=false
if aws secretsmanager describe-secret --region "$REGION" \
  --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
  SECRET_EXISTS=true
  EXISTING_SECRET="$(
    aws secretsmanager get-secret-value --region "$REGION" \
      --secret-id "$SECRET_NAME" --query SecretString --output text
  )"
  DB_USERNAME="$(jq -r '.username // "skills"' <<<"$EXISTING_SECRET")"
  DB_PASSWORD="$(jq -r '.password // empty' <<<"$EXISTING_SECRET")"
else
  DB_PASSWORD=""
fi
if [[ -z "$DB_PASSWORD" ]]; then
  DB_PASSWORD="$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | cut -c1-30)"
fi

if [[ "$SECRET_EXISTS" != true ]]; then
  INITIAL_SECRET_JSON="$(
    jq -cn \
      --arg username "$DB_USERNAME" \
      --arg password "$DB_PASSWORD" \
      '{username:$username,password:$password,host:""}'
  )"
  aws secretsmanager create-secret --region "$REGION" \
    --name "$SECRET_NAME" \
    --description "DocumentDB credentials for skills NoSQL application" \
    --kms-key-id "$KMS_KEY_ARN" \
    --secret-string "$INITIAL_SECRET_JSON" \
    --tags Key=Name,Value="$SECRET_NAME" >/dev/null
  SECRET_EXISTS=true
fi

CLUSTER_EXISTS=false
if aws docdb describe-db-clusters --region "$REGION" \
  --db-cluster-identifier "$CLUSTER_ID" >/dev/null 2>&1; then
  CLUSTER_EXISTS=true
else
  aws docdb create-db-cluster --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --engine docdb \
    --master-username "$DB_USERNAME" \
    --master-user-password "$DB_PASSWORD" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --vpc-security-group-ids "$DOCDB_SG_ID" \
    --storage-encrypted \
    --kms-key-id "$KMS_KEY_ARN" \
    --backup-retention-period 1 \
    --tags Key=Name,Value="$CLUSTER_ID" >/dev/null
fi
if [[ "$CLUSTER_EXISTS" == true && "$RESET_DOCDB_PASSWORD" == true ]]; then
  echo "기존 DocumentDB의 Master 비밀번호를 Secret과 동기화합니다."
  aws docdb modify-db-cluster --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --master-user-password "$DB_PASSWORD" \
    --apply-immediately >/dev/null
fi
if ! aws docdb describe-db-instances --region "$REGION" \
  --db-instance-identifier "$INSTANCE_ID" >/dev/null 2>&1; then
  aws docdb create-db-instance --region "$REGION" \
    --db-instance-identifier "$INSTANCE_ID" \
    --db-instance-class db.t3.medium \
    --engine docdb \
    --db-cluster-identifier "$CLUSTER_ID" \
    --tags Key=Name,Value="$INSTANCE_ID" >/dev/null
fi

CLUSTER_READY=false
for attempt in {1..120}; do
  CLUSTER_STATUS="$(
    aws docdb describe-db-clusters --region "$REGION" \
      --db-cluster-identifier "$CLUSTER_ID" \
      --query 'DBClusters[0].Status' --output text
  )"
  if [[ "$CLUSTER_STATUS" == "available" ]]; then
    CLUSTER_READY=true
    break
  fi
  case "$CLUSTER_STATUS" in
    failed | deleting | incompatible-* )
      echo "ERROR: DocumentDB Cluster 상태: ${CLUSTER_STATUS}" >&2
      exit 1
      ;;
  esac
  sleep 15
done
if [[ "$CLUSTER_READY" != true ]]; then
  echo "ERROR: DocumentDB Cluster 준비 시간이 초과됐습니다." >&2
  exit 1
fi
aws docdb wait db-instance-available --region "$REGION" \
  --db-instance-identifier "$INSTANCE_ID"
DOCDB_HOST="$(
  aws docdb describe-db-clusters --region "$REGION" \
    --db-cluster-identifier "$CLUSTER_ID" \
    --query 'DBClusters[0].Endpoint' --output text
)"

SECRET_JSON="$(
  jq -cn \
    --arg username "$DB_USERNAME" \
    --arg password "$DB_PASSWORD" \
    --arg host "$DOCDB_HOST" \
    '{username:$username,password:$password,host:$host}'
)"
if [[ "$SECRET_EXISTS" == true ]]; then
  aws secretsmanager update-secret --region "$REGION" \
    --secret-id "$SECRET_NAME" \
    --kms-key-id "$KMS_KEY_ARN" \
    --secret-string "$SECRET_JSON" >/dev/null
else
  aws secretsmanager create-secret --region "$REGION" \
    --name "$SECRET_NAME" \
    --description "DocumentDB credentials for skills NoSQL application" \
    --kms-key-id "$KMS_KEY_ARN" \
    --secret-string "$SECRET_JSON" \
    --tags Key=Name,Value="$SECRET_NAME" >/dev/null
fi

cat >"${TMP_DIR}/trust-policy.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
JSON
if ! aws iam get-role --role-name "$CLIENT_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$CLIENT_ROLE" \
    --assume-role-policy-document "file://${TMP_DIR}/trust-policy.json" \
    --tags Key=Name,Value="$CLIENT_ROLE" >/dev/null
fi
cat >"${TMP_DIR}/client-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:${SECRET_NAME}-*"
    },
    {
      "Effect": "Allow",
      "Action": "kms:Decrypt",
      "Resource": "${KMS_KEY_ARN}"
    }
  ]
}
JSON
aws iam put-role-policy --role-name "$CLIENT_ROLE" \
  --policy-name skills-nosql-client-secret-read \
  --policy-document "file://${TMP_DIR}/client-policy.json"
if ! aws iam get-instance-profile \
  --instance-profile-name "$CLIENT_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile \
    --instance-profile-name "$CLIENT_PROFILE" \
    --tags Key=Name,Value="$CLIENT_PROFILE" >/dev/null
fi
PROFILE_ROLE="$(
  aws iam get-instance-profile --instance-profile-name "$CLIENT_PROFILE" \
    --query 'InstanceProfile.Roles[0].RoleName' --output text
)"
if [[ -z "$PROFILE_ROLE" || "$PROFILE_ROLE" == "None" ]]; then
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$CLIENT_PROFILE" \
    --role-name "$CLIENT_ROLE"
  sleep 10
fi

CLIENT_PY_GZ="$(gzip -9c "$DOCDB_CLIENT" | base64 | tr -d '\r\n')"
DATASET_GZ="$(gzip -9c "$DATASET" | base64 | tr -d '\r\n')"
cat >"${TMP_DIR}/user-data.sh" <<USERDATA
#!/usr/bin/env bash
set -euo pipefail
exec > >(tee /var/log/skills-nosql-bootstrap.log | logger -t user-data -s 2>/dev/console) 2>&1

yum install python3-pip -y
pip3 install pymongo boto3 Flask
mkdir -p /opt/skills-nosql
chown -R ec2-user:ec2-user /opt/skills-nosql
curl --fail --retry 5 \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o /opt/skills-nosql/global-bundle.pem
echo '${CLIENT_PY_GZ}' | base64 -d | gzip -d > /opt/skills-nosql/docdb_client.py
echo '${DATASET_GZ}' | base64 -d | gzip -d > /opt/skills-nosql/retail_dataset.json
chown -R ec2-user:ec2-user /opt/skills-nosql
chmod 755 /opt/skills-nosql/docdb_client.py

cat >/opt/skills-nosql/make_index.py <<'PY'
import json
import boto3
from pymongo import MongoClient
from urllib.parse import quote_plus

secret_client = boto3.client("secretsmanager", region_name="ap-northeast-2")
res = secret_client.get_secret_value(SecretId="skills-nosql-docdb-secret")
secret = json.loads(res["SecretString"])
uri = (
    f"mongodb://{quote_plus(secret['username'])}:{quote_plus(secret['password'])}"
    f"@{secret['host']}:27017/"
    "?replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false"
)
client = MongoClient(
    uri,
    tls=True,
    tlsCAFile="/opt/skills-nosql/global-bundle.pem",
    serverSelectionTimeoutMS=8000,
)
db = client["skills_retail"]
db.orders.create_index([("orderId", 1)], unique=True)
db.orders.create_index([("customerId", 1), ("createdAt", -1)])
db.orders.create_index([("status", 1), ("dueAt", 1)])
db.products.create_index([("productId", 1)], unique=True)
db.products.create_index([("warehouseId", 1), ("stock", 1)])
db.sessions.create_index([("sessionId", 1)], unique=True)
db.sessions.create_index([("expiresAt", 1)], expireAfterSeconds=0)
db.sessions.create_index([("customerId", 1), ("lastSeen", -1)])
print("[OK] required indexes created")
PY
chown ec2-user:ec2-user /opt/skills-nosql/make_index.py

ready=false
for attempt in {1..40}; do
  if runuser -u ec2-user -- bash -c \
    'cd /opt/skills-nosql && python3 ./docdb_client.py seed && python3 ./make_index.py && python3 ./docdb_client.py counts'; then
    ready=true
    break
  fi
  sleep 15
done
[[ "\$ready" == true ]]

cat >/etc/systemd/system/skills-nosql.service <<'SERVICE'
[Unit]
Description=Skills DocumentDB NoSQL client application
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/skills-nosql
ExecStart=/usr/bin/python3 /opt/skills-nosql/docdb_client.py serve
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable --now skills-nosql.service
USERDATA

USER_DATA_SIZE="$(wc -c <"${TMP_DIR}/user-data.sh")"
if (( USER_DATA_SIZE > 16000 )); then
  echo "ERROR: EC2 User Data가 16KB 제한을 초과했습니다: ${USER_DATA_SIZE} bytes" >&2
  exit 1
fi

CLIENT_INSTANCE_ID="$(
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${CLIENT_NAME}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
)"
if [[ "$RECREATE_CLIENT_EC2" == true &&
      -n "$CLIENT_INSTANCE_ID" && "$CLIENT_INSTANCE_ID" != "None" ]]; then
  echo "실패한 기존 Client EC2를 종료하고 다시 생성합니다: ${CLIENT_INSTANCE_ID}"
  aws ec2 terminate-instances --region "$REGION" \
    --instance-ids "$CLIENT_INSTANCE_ID" >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" \
    --instance-ids "$CLIENT_INSTANCE_ID"
  CLIENT_INSTANCE_ID="None"
fi
if [[ -z "$CLIENT_INSTANCE_ID" || "$CLIENT_INSTANCE_ID" == "None" ]]; then
  AMI_ID="$(
    aws ssm get-parameter --region "$REGION" \
      --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
      --query Parameter.Value --output text
  )"
  CLIENT_INSTANCE_ID="$(
    aws ec2 run-instances --region "$REGION" \
      --image-id "$AMI_ID" \
      --instance-type t3.micro \
      --subnet-id "${PUBLIC_SUBNETS[0]}" \
      --security-group-ids "$CLIENT_SG_ID" \
      --iam-instance-profile "Name=${CLIENT_PROFILE}" \
      --associate-public-ip-address \
      --metadata-options HttpTokens=required,HttpEndpoint=enabled \
      --user-data "file://${TMP_DIR}/user-data.sh" \
      --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${CLIENT_NAME}}]" \
        "ResourceType=volume,Tags=[{Key=Name,Value=${CLIENT_NAME}}]" \
      --query 'Instances[0].InstanceId' --output text
  )"
else
  STATE="$(
    aws ec2 describe-instances --region "$REGION" \
      --instance-ids "$CLIENT_INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].State.Name' --output text
  )"
  if [[ "$STATE" == "stopped" ]]; then
    aws ec2 start-instances --region "$REGION" \
      --instance-ids "$CLIENT_INSTANCE_ID" >/dev/null
  fi
fi
aws ec2 wait instance-running --region "$REGION" \
  --instance-ids "$CLIENT_INSTANCE_ID"
CLIENT_IP="$(
  aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$CLIENT_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
)"

APP_READY=false
for attempt in {1..60}; do
  if curl --silent --show-error --fail --max-time 5 \
    "http://${CLIENT_IP}:8080/health"; then
    echo
    APP_READY=true
    break
  fi
  sleep 10
done
if [[ "$APP_READY" != true ]]; then
  echo "WARNING: EC2는 생성됐지만 앱 준비 확인 시간이 초과됐습니다." >&2
  echo "EC2 콘솔의 /var/log/skills-nosql-bootstrap.log를 확인하세요." >&2
  exit 1
fi