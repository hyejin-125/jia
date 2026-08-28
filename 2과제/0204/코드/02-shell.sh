#!/bin/bash
set -x

if [[ -z "${EXAM_NO:-}" || "${EXAM_NO}" == "<비번호>" || "${EXAM_NO}" == "<exam-number>" ]]; then
  echo "[오류] 비번호(EXAM_NO)가 제대로 설정되지 않았습니다." >&2
  echo "터미널에 아래 명령어를 실행하여 본인의 비번호를 먼저 설정한 뒤 다시 실행하세요:" >&2
  echo '  export EXAM_NO="1"  # (본인의 실제 비번호로 변경)' >&2
  exit 1
fi

export AWS_DEFAULT_REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

VPC_NAME="msk-vpc"
PRIV_A_NAME="msk-priv-a"; PRIV_B_NAME="msk-priv-b"
MSK_CLUSTER_NAME="wsc2026-msk-cluster"; RAW_TOPIC="wsc2026-sensor-raw"; ALERT_TOPIC="wsc2026-sensor-alert"
RAW_FN="wsc2026-sensor-consumer"; ALERT_FN="wsc2026-sensor-alert-consumer"; TABLE_NAME="wsc2026-sensor-data"
BUCKET_NAME="wsc2026-sensor-alert-bucket-${EXAM_NO}"
SNS_TOPIC_ARN="arn:aws:sns:${AWS_DEFAULT_REGION}:${ACCOUNT_ID}:wsc2026-sensor-alert"
EC2_PROFILE_NAME="wsc2026-msk-ec2-profile"; LAMBDA_ROLE_NAME="wsc2026-msk-lambda-role"
PRODUCER_INSTANCE_NAME="wsc2026-sensor-producer"
PRODUCER_SG_NAME="wsc2026-sensor-producer-sg"; LAMBDA_SG_NAME="wsc2026-msk-lambda-sg"
KEY_NAME="${KEY_NAME:-}"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${VPC_NAME}" --query "Vpcs[0].VpcId" --output text)
PRIV_A=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PRIV_A_NAME}" --query "Subnets[0].SubnetId" --output text)
PRIV_B=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PRIV_B_NAME}" --query "Subnets[0].SubnetId" --output text)
PRODUCER_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${PRODUCER_SG_NAME}" --query "SecurityGroups[0].GroupId" --output text)
LAMBDA_SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${LAMBDA_SG_NAME}" --query "SecurityGroups[0].GroupId" --output text)
CLUSTER_ARN=$(aws kafka list-clusters-v2 --cluster-name-filter "$MSK_CLUSTER_NAME" --query "ClusterInfoList[0].ClusterArn" --output text)

while true; do
  state=$(aws kafka describe-cluster --cluster-arn "$CLUSTER_ARN" --query "ClusterInfo.State" --output text)
  echo "현재 MSK 상태: ${state}"
  [[ "$state" == "ACTIVE" ]] && break
  [[ "$state" == "FAILED" ]] && { echo "MSK 생성 실패!" >&2; exit 1; }
  echo "아직 생성 중입니다. 60초 후 다시 확인합니다..."
  sleep 60
done

BOOTSTRAP_SERVER=$(aws kafka get-bootstrap-brokers --cluster-arn "$CLUSTER_ARN" --query "BootstrapBrokerStringSaslIam" --output text)
echo "BOOTSTRAP_SERVER=${BOOTSTRAP_SERVER}"

cat <<EOF_USERDATA > /tmp/producer_userdata.sh
#!/bin/bash
set -euo pipefail
if command -v dnf >/dev/null 2>&1; then dnf install -y python3-pip; else apt-get update && apt-get install -y python3-pip; fi
python3 -m pip install --quiet kafka-python aws-msk-iam-sasl-signer-python
mkdir -p /opt/msk-producer
cat > /opt/msk-producer/topic_setup.py <<'PY'
import time
from kafka import KafkaAdminClient
from kafka.admin import NewTopic
from kafka.errors import TopicAlreadyExistsError
from kafka.net.sasl.oauth import AbstractTokenProvider
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
BOOTSTRAP = "${BOOTSTRAP_SERVER}".split(",")
REGION = "${AWS_DEFAULT_REGION}"
class TokenProvider(AbstractTokenProvider):
    def token(self):
        token, _ = MSKAuthTokenProvider.generate_auth_token(REGION)
        return token
for _ in range(30):
    try:
        client = KafkaAdminClient(bootstrap_servers=BOOTSTRAP, security_protocol="SASL_SSL", sasl_mechanism="OAUTHBEARER", sasl_oauth_token_provider=TokenProvider(), client_id="topic-setup")
        client.create_topics(new_topics=[NewTopic(name="${RAW_TOPIC}", num_partitions=3, replication_factor=2), NewTopic(name="${ALERT_TOPIC}", num_partitions=1, replication_factor=2)], validate_only=False)
        client.close(); break
    except TopicAlreadyExistsError: client.close(); break
    except Exception: time.sleep(30)
PY
python3 /opt/msk-producer/topic_setup.py


cat > /opt/msk-producer/producer.py <<'PY'
import json, time, datetime
from kafka import KafkaProducer
from kafka.net.sasl.oauth import AbstractTokenProvider
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

BOOTSTRAP = "${BOOTSTRAP_SERVER}".split(",")
REGION = "${AWS_DEFAULT_REGION}"

class TokenProvider(AbstractTokenProvider):
    def token(self):
        token, _ = MSKAuthTokenProvider.generate_auth_token(REGION)
        return token
producer = KafkaProducer(bootstrap_servers=BOOTSTRAP, security_protocol="SASL_SSL", sasl_mechanism="OAUTHBEARER", sasl_oauth_token_provider=TokenProvider(), key_serializer=lambda v: v.encode("utf-8"), value_serializer=lambda v: json.dumps(v).encode("utf-8"))

while True:
    current_kst = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).strftime('%Y-%m-%dT%H:%M:%S+09:00')
    payload = {"sensorId": "SENSOR-002", "timestamp": current_kst, "temperature": 64.6, "humidity": 48.2, "location": "factory-b"}
    producer.send("${RAW_TOPIC}", key=payload["sensorId"], value=payload); producer.flush(); time.sleep(5)
PY

cat > /etc/systemd/system/app.service <<'EOF2'
[Unit]
Description=MSK Sensor Producer
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/msk-producer/producer.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF2
systemctl daemon-reload; systemctl enable app; systemctl restart app
touch /opt/msk-producer/ready
EOF_USERDATA

INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${PRODUCER_INSTANCE_NAME}" "Name=instance-state-name,Values=running,pending,stopped,stopping" --query "Reservations[0].Instances[0].InstanceId" --output text)
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  AMI_ID=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query "Parameters[0].Value" --output text)
  INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.small --subnet-id "$PRIV_A" --security-group-ids "$PRODUCER_SG" --iam-instance-profile "Name=${EC2_PROFILE_NAME}" --user-data file:///tmp/producer_userdata.sh --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PRODUCER_INSTANCE_NAME}}]" ${KEY_NAME:+--key-name "$KEY_NAME"} --query "Instances[0].InstanceId" --output text)
else
  aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
fi
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

rm -rf /tmp/raw_lambda_build /tmp/alert_lambda_build /tmp/raw_lambda.zip /tmp/alert_lambda.zip
mkdir -p /tmp/raw_lambda_build /tmp/alert_lambda_build
cat > /tmp/raw_lambda_build/index.py <<'PY'
import base64, json, os, boto3
ddb = boto3.resource("dynamodb").Table(os.environ["DDB_TABLE"])
def classify(data):
    t, h = float(data["temperature"]), float(data["humidity"])
    if t > 80: return "ALERT", f"Temperature exceeded threshold: {t}°C"
    if t < 10: return "ALERT", f"Temperature below threshold: {t}°C"
    if h > 90: return "ALERT", f"Humidity exceeded threshold: {h}%"
    if h < 20: return "ALERT", f"Humidity below threshold: {h}%"
    return "NORMAL", None
def handler(event, context):
    a_cnt, n_cnt = 0, 0
    for records in event.get("records", {}).values():
        for record in records:
            payload = json.loads(base64.b64decode(record["value"]).decode("utf-8"))
            item = {"sensorId": str(payload["sensorId"]), "timestamp": str(payload["timestamp"]), "temperature": str(payload["temperature"]), "humidity": str(payload["humidity"]), "location": str(payload["location"])}
            status, reason = classify(payload); item["status"] = status
            if reason: item["alert_reason"] = reason; a_cnt += 1
            else: n_cnt += 1
            ddb.put_item(Item=item)
    return {"normal_count": n_cnt, "alert_count": a_cnt}
PY
cat > /tmp/alert_lambda_build/index.py <<'PY'
import base64, json, os, boto3
s3, sns = boto3.client("s3"), boto3.client("sns")
def handler(event, context):
    cnt = 0
    for records in event.get("records", {}).values():
        for record in records:
            payload = json.loads(base64.b64decode(record["value"]).decode("utf-8"))
            sid, ts = str(payload["sensorId"]), str(payload["timestamp"])
            key = f"alert/{sid}/{ts[:10]}/{ts}.json"; body = json.dumps(payload, ensure_ascii=False)
            s3.put_object(Bucket=os.environ["S3_BUCKET"], Key=key, Body=body.encode("utf-8"), ContentType="application/json")
            sns.publish(TopicArn=os.environ["SNS_TOPIC_ARN"], Subject=f"Sensor alert: {sid}", Message=body)
            cnt += 1
    return {"status": "ok", "records": cnt}
PY
python3 - <<'PY'
from pathlib import Path
import zipfile
def make_zip(src, dst):
    with zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for p in Path(src).rglob("*"):
            if p.is_file(): zf.write(p, p.relative_to(src))
make_zip("/tmp/raw_lambda_build", "/tmp/raw_lambda.zip")
make_zip("/tmp/alert_lambda_build", "/tmp/alert_lambda.zip")
PY

cat > /tmp/raw_env.json <<EOF
{"Variables":{"ALERT_TOPIC":"${ALERT_TOPIC}","DDB_TABLE":"${TABLE_NAME}","MY_AWS_REGION":"${AWS_DEFAULT_REGION}","BOOTSTRAP_SERVER":"${BOOTSTRAP_SERVER}"}}
EOF
cat > /tmp/alert_env.json <<EOF
{"Variables":{"S3_BUCKET":"${BUCKET_NAME}","SNS_TOPIC_ARN":"${SNS_TOPIC_ARN}"}}
EOF

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"
for fn in "$RAW_FN" "$ALERT_FN"; do
  zip="/tmp/${fn#wsc2026-sensor-}_lambda.zip"; [[ "$fn" == "$RAW_FN" ]] && zip="/tmp/raw_lambda.zip" || zip="/tmp/alert_lambda.zip"
  env="/tmp/${fn#wsc2026-sensor-}_env.json"; [[ "$fn" == "$RAW_FN" ]] && env="/tmp/raw_env.json" || env="/tmp/alert_env.json"
  if aws lambda get-function --function-name "$fn" >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$fn" --zip-file "fileb://${zip}" >/dev/null
    aws lambda update-function-configuration --function-name "$fn" --runtime python3.14 --role "$ROLE_ARN" --handler index.handler --timeout 60 --vpc-config "SubnetIds=${PRIV_A},${PRIV_B},SecurityGroupIds=${LAMBDA_SG}" --environment "file://${env}" >/dev/null
  else
    aws lambda create-function --function-name "$fn" --runtime python3.14 --role "$ROLE_ARN" --handler index.handler --timeout 60 --zip-file "fileb://${zip}" --vpc-config "SubnetIds=${PRIV_A},${PRIV_B},SecurityGroupIds=${LAMBDA_SG}" --environment "file://${env}" >/dev/null
  fi
  aws lambda wait function-updated --function-name "$fn"
done

ensure_mapping() {
  local fn="$1" topic="$2" uuid=$(aws lambda list-event-source-mappings --function-name "$fn" --query "EventSourceMappings[0].UUID" --output text)
  if [[ -z "$uuid" || "$uuid" == "None" ]]; then
    for _ in $(seq 1 20); do
      if aws lambda create-event-source-mapping --function-name "$fn" --event-source-arn "$CLUSTER_ARN" --topics "$topic" --starting-position LATEST >/dev/null 2>&1; then return 0; fi
      sleep 30
    done
  else
    aws lambda update-event-source-mapping --uuid "$uuid" --enabled >/dev/null
  fi
}
ensure_mapping "$RAW_FN" "$RAW_TOPIC"
ensure_mapping "$ALERT_FN" "$ALERT_TOPIC"

CURRENT_KST=$(TZ="Asia/Seoul" date +"%Y-%m-%dT%H:%M:%S+09:00")
aws dynamodb put-item --table-name "$TABLE_NAME" --item '{"sensorId":{"S":"SENSOR-002"},"timestamp":{"S":"'"$CURRENT_KST"'"},"temperature":{"S":"64.6"},"humidity":{"S":"48.2"},"location":{"S":"factory-b"},"status":{"S":"NORMAL"}}' >/dev/null