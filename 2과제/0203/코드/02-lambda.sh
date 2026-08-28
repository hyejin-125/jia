#!/bin/bash
set -x

aws configure set cli_pager ""
export AWS_PAGER=""
REGION="eu-west-1"
ROLE_NAME="wsc2026-event-lambda-role"
SNS_TOPIC_ARN=$(aws sns list-topics --region $REGION --query "Topics[?contains(TopicArn, 'wsc2026-event-alert')].TopicArn" --output text)

cat << 'EOF' > lambda-trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file://lambda-trust.json 2>/dev/null || true
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonSNSFullAccess

sleep 5
ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)

deploy_fast() {
    local func_name=$1
    local code_file=$2
    
    echo "=== Deploying: $func_name ==="
    zip -j function.zip $code_file
    
    aws lambda update-function-code \
        --function-name $func_name \
        --zip-file fileb://function.zip \
        --region $REGION >/dev/null 2>&1 || \
    aws lambda create-function \
        --function-name $func_name \
        --runtime python3.12 \
        --role $ROLE_ARN \
        --handler ${code_file%.py}.lambda_handler \
        --zip-file fileb://function.zip \
        --environment "Variables={SNS_TOPIC_ARN=$SNS_TOPIC_ARN}" \
        --region $REGION \
        --timeout 30 >/dev/null 2>&1
    
    rm -f function.zip
}

cat << 'EOF' > stop_code.py
import os
import json
from datetime import datetime
import boto3
ec2_client = boto3.client('ec2')
sns_client = boto3.client('sns')
instance_id = "i-placeholder"
sg_id = "sg-placeholder"
sns_topic_arn = os.environ.get("SNS_TOPIC_ARN")
def lambda_handler(event, context):
    try:
        detail = event.get('detail', {})
        instance_ids = detail.get('instance-id', [instance_id])
        if isinstance(instance_ids, str):
            instance_ids = [instance_ids]
        for i_id in instance_ids:
            ec2_client.start_instances(InstanceIds=[i_id])
    except Exception as e:
        print(f"Error: {e}")
    message = {
        "event": "EC2_STOPPED",
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "detail": f"EC2 instance was stopped and restarted",
        "action": "RESTORED"
    }
    if sns_topic_arn:
        sns_client.publish(TopicArn=sns_topic_arn, Message=json.dumps(message))
    return {"statusCode": 200, "body": "EC2 Restarted and Notified"}
EOF
deploy_fast "wsc2026-ec2-stop-remediation" "stop_code.py"

cat << 'EOF' > terminate_code.py
import os
import json
from datetime import datetime
import boto3
sns_client = boto3.client('sns')
sns_topic_arn = os.environ.get("SNS_TOPIC_ARN")
def lambda_handler(event, context):
    message = {
        "event": "EC2_TERMINATED",
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "detail": f"EC2 instance was terminated",
        "action": "ALERT_ONLY"
    }
    if sns_topic_arn:
        sns_client.publish(TopicArn=sns_topic_arn, Message=json.dumps(message))
    return {"statusCode": 200, "body": "EC2 Terminate Notified"}
EOF
deploy_fast "wsc2026-ec2-terminate-alert" "terminate_code.py"

cat << 'EOF' > sg_code.py
import os
import json
import boto3
from datetime import datetime
ec2_client = boto3.client('ec2')
sns_client = boto3.client('sns')
sns_topic_arn = os.environ.get("SNS_TOPIC_ARN")
def lambda_handler(event, context):
    try:
        detail = event.get('detail', {})
        resource_id = detail.get('resourceId') or detail.get('requestParameters', {}).get('groupId')
        if resource_id and resource_id.startswith('sg-'):
            ec2_client.revoke_security_group_ingress(
                GroupId=resource_id,
                IpPermissions=[{
                    'IpProtocol': 'tcp',
                    'FromPort': 22,
                    'ToPort': 22,
                    'IpRanges': [{'CidrIp': '0.0.0.0/0'}]
                }]
            )
    except Exception as e:
        print(f"Revoke error: {str(e)}")
    payload = {
        "event": "SG_SSH_OPEN",
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "detail": f"Security Group global SSH access removed",
        "action": "RESTORED"
    }
    if sns_topic_arn:
        try:
            sns_client.publish(TopicArn=sns_topic_arn, Message=json.dumps(payload))
        except Exception:
            pass
    return {"statusCode": 200, "body": "Remediation executed."}
EOF
deploy_fast "wsc2026-sg-remediation" "sg_code.py"

cat << 'EOF' > tag_code.py
import os
import json
from datetime import datetime
import boto3
sns_client = boto3.client('sns')
sns_topic_arn = os.environ.get("SNS_TOPIC_ARN")
def lambda_handler(event, context):
    detail = event.get('detail', {})
    compliance = detail.get('newEvaluationResult', {}).get('complianceType', '')
    if compliance == 'NON_COMPLIANT':
        resource_id = detail.get('resourceId', 'unknown-resource')
        resource_type = detail.get('resourceType', 'unknown-type')
        message = {
            "event": "TAG_MISSING",
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "detail": f"Required tags are missing on resource {resource_id} ({resource_type})",
            "action": "ALERT_ONLY"
        }
        if sns_topic_arn:
            sns_client.publish(TopicArn=sns_topic_arn, Message=json.dumps(message))
    return {"statusCode": 200, "body": "Tag Non-Compliance Notified"}
EOF
deploy_fast "wsc2026-tag-alert" "tag_code.py"

rm -f stop_code.py terminate_code.py sg_code.py tag_code.py lambda-trust.json

echo