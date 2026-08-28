#!/bin/bash
set -x

REGION="ap-southeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
TIMESTAMP=$(date +%s)


SNS_TOPIC_ARN=$(aws sns create-topic --region $REGION \
    --name "skills-ceh-alert-topic" \
    --tags Key=Name,Value=skills-ceh-alert-topic \
    --query "TopicArn" --output text)
echo "SNS Topic ARN: $SNS_TOPIC_ARN"


# CloudTrail 로그 저장을 위한 고유한 S3 버킷 생성
BUCKET_NAME="skills-ceh-cloudtrail-logs-${ACCOUNT_ID}-${TIMESTAMP}"
aws s3api create-bucket --region $REGION \
    --bucket $BUCKET_NAME \
    --create-bucket-configuration LocationConstraint=$REGION > /dev/null

# CloudTrail S3 버킷 정책 적용
cat << EOF > /tmp/ct-bucket-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AWSCloudTrailAclCheck",
            "Effect": "Allow",
            "Principal": {"Service": "cloudtrail.amazonaws.com"},
            "Action": "s3:GetBucketAcl",
            "Resource": "arn:aws:s3:::$BUCKET_NAME"
        },
        {
            "Sid": "AWSCloudTrailWrite",
            "Effect": "Allow",
            "Principal": {"Service": "cloudtrail.amazonaws.com"},
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::$BUCKET_NAME/AWSLogs/$ACCOUNT_ID/*",
            "Condition": {"StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control"}}
        }
    ]
}
EOF
aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy file:///tmp/ct-bucket-policy.json
rm -f /tmp/ct-bucket-policy.json

# CloudTrail 생성 및 로깅 활성화
aws cloudtrail create-trail --region $REGION \
      --name "skills-ceh-cloudtrail" \
      --s3-bucket-name $BUCKET_NAME \
      --is-multi-region-trail \
      --tags-list Key=Name,Value=skills-ceh-cloudtrail > /dev/null

aws cloudtrail start-logging --region $REGION --name "skills-ceh-cloudtrail"
echo "CloudTrail 'skills-ceh-cloudtrail' 생성 및 로깅 시작 완료 (S3: $BUCKET_NAME)"


# Trust Policy
cat << EOF > /tmp/lambda-trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

ROLE_ARN=$(aws iam create-role \
    --role-name "skills-ceh-remediate-role-$TIMESTAMP" \
    --assume-role-policy-document file:///tmp/lambda-trust.json \
    --query "Role.Arn" --output text)
rm -f /tmp/lambda-trust.json

# Permissions Policy (SG 조회/수정, SNS 발행, CloudWatch Logs 기록)
cat << EOF > /tmp/lambda-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeSecurityGroups",
        "ec2:RevokeSecurityGroupIngress",
        "sns:Publish",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
    --role-name "skills-ceh-remediate-role-$TIMESTAMP" \
    --policy-name "skills-ceh-remediate-policy" \
    --policy-document file:///tmp/lambda-policy.json
rm -f /tmp/lambda-policy.json

echo "IAM Role 생성 완료. 권한 전파 대기 중 (10초)..."
sleep 10


mkdir -p /tmp/lambda_build
cd /tmp/lambda_build

cat << 'EOF' > remediate_security_group.py
import json
import os
import time
from typing import Any, Dict, List, Optional

import boto3
from botocore.exceptions import ClientError


ec2 = boto3.client("ec2")
sns = boto3.client("sns")


def _find_first_group_id(value: Any) -> Optional[str]:
    if isinstance(value, dict):
        for key in ("groupId", "GroupId", "groupID"):
            item = value.get(key)
            if isinstance(item, str) and item.startswith("sg-"):
                return item
        for item in value.values():
            found = _find_first_group_id(item)
            if found:
                return found
    if isinstance(value, list):
        for item in value:
            found = _find_first_group_id(item)
            if found:
                return found
    return None


def _extract_group_id(event: Dict[str, Any]) -> Optional[str]:
    detail = event.get("detail", {})
    request_parameters = detail.get("requestParameters", {})
    response_elements = detail.get("responseElements", {})
    return _find_first_group_id(request_parameters) or _find_first_group_id(response_elements)


def _describe_ingress_permissions(group_id: str) -> List[Dict[str, Any]]:
    response = ec2.describe_security_groups(GroupIds=[group_id])
    groups = response.get("SecurityGroups", [])
    if not groups:
        return []
    return groups[0].get("IpPermissions", [])


def _revoke_all_ingress(group_id: str, permissions: List[Dict[str, Any]]) -> int:
    if not permissions:
        return 0
    ec2.revoke_security_group_ingress(GroupId=group_id, IpPermissions=permissions)
    return len(permissions)


def _publish(topic_arn: str, payload: Dict[str, Any]) -> None:
    subject = "Security Group remediated"
    sns.publish(TopicArn=topic_arn, Subject=subject, Message=json.dumps(payload, ensure_ascii=False, indent=2, default=str))


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    protected_group_id = os.environ["PROTECTED_SECURITY_GROUP_ID"]
    topic_arn = os.environ["SNS_TOPIC_ARN"]

    event_name = event.get("detail", {}).get("eventName", "")
    event_group_id = _extract_group_id(event)
    request_id = event.get("detail", {}).get("requestID", "")

    if event_group_id != protected_group_id:
        result = {
            "status": "IGNORED",
            "reason": "event is not for the protected security group",
            "eventName": event_name,
            "eventGroupId": event_group_id,
            "protectedGroupId": protected_group_id,
            "requestId": request_id,
            "timestamp": int(time.time()),
        }
        print(json.dumps(result, ensure_ascii=False, default=str))
        return result

    permissions = _describe_ingress_permissions(protected_group_id)
    revoked_count = 0
    publish_status = "NOT_REQUIRED"

    try:
        revoked_count = _revoke_all_ingress(protected_group_id, permissions)
        status = "RESTORED" if revoked_count else "NO_ACTION"
    except ClientError as exc:
        result = {
            "status": "REMEDIATION_FAILED",
            "eventName": event_name,
            "eventGroupId": event_group_id,
            "protectedGroupId": protected_group_id,
            "requestId": request_id,
            "error": str(exc),
            "timestamp": int(time.time()),
        }
        print(json.dumps(result, ensure_ascii=False, default=str))
        raise

    result = {
        "status": status,
        "eventName": event_name,
        "eventGroupId": event_group_id,
        "protectedGroupId": protected_group_id,
        "requestId": request_id,
        "revokedPermissionCount": revoked_count,
        "timestamp": int(time.time()),
    }

    try:
        _publish(topic_arn, result)
        publish_status = "SNS_PUBLISHED"
    except Exception as exc:
        publish_status = "SNS_PUBLISH_FAILED"
        result["snsError"] = str(exc)

    result["publishStatus"] = publish_status
    print(json.dumps(result, ensure_ascii=False, default=str))
    return result
EOF

zip -q remediate_fn.zip remediate_security_group.py

PROTECTED_SG_ID=$(aws ec2 describe-security-groups --region $REGION --filters Name=tag:Name,Values=skills-ceh-protected-sg --query 'SecurityGroups[0].GroupId' --output text)
LAMBDA_ARN=$(aws lambda create-function --region $REGION \
    --function-name "skills-ceh-remediate-fn" \
    --runtime "python3.12" \
    --role "$ROLE_ARN" \
    --handler "remediate_security_group.lambda_handler" \
    --timeout 30 \
    --zip-file "fileb://remediate_fn.zip" \
    --environment "Variables={PROTECTED_SECURITY_GROUP_ID=$PROTECTED_SG_ID,SNS_TOPIC_ARN=$SNS_TOPIC_ARN}" \
    --tags "Name=skills-ceh-remediate-fn" \
    --query "FunctionArn" --output text)

cd - > /dev/null
rm -rf /tmp/lambda_build
echo "Lambda 함수 ARN: $LAMBDA_ARN"


cat << EOF > /tmp/eb-pattern.json
{
  "source": ["aws.ec2"],
  "detail-type": ["EC2 API Call via CloudTrail"],
  "detail": {
    "eventSource": ["ec2.amazonaws.com"],
    "eventName": ["AuthorizeSecurityGroupIngress"]
  }
}
EOF

RULE_ARN=$(aws events put-rule --region $REGION \
    --name "skills-ceh-sg-change-rule" \
    --event-bus-name "default" \
    --event-pattern file:///tmp/eb-pattern.json \
    --tags Key=Name,Value=skills-ceh-sg-change-rule \
    --query "RuleArn" --output text)
rm -f /tmp/eb-pattern.json
echo "EventBridge Rule ARN: $RULE_ARN"

aws lambda add-permission --region $REGION \
    --function-name "skills-ceh-remediate-fn" \
    --statement-id "AllowEventBridgeInvoke-$TIMESTAMP" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "$RULE_ARN" > /dev/null

aws events put-targets --region $REGION \
    --rule "skills-ceh-sg-change-rule" \
    --targets "Id"="1","Arn"="$LAMBDA_ARN" > /dev/null