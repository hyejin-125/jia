#!/bin/bash
set -x

aws configure set cli_binary_format raw-in-base64-out
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CONFIG_BUCKET="wsc2026-config-bucket-$ACCOUNT_ID"

setup_rule() {
    local rule_name=$1
    local pattern=$2
    local func_name=$3
    
    aws events put-rule --name "$rule_name" --region $REGION --event-pattern "$pattern"
    LAMBDA_ARN=$(aws lambda get-function --function-name "$func_name" --region $REGION --query "Configuration.FunctionArn" --output text)
    aws events put-targets --rule "$rule_name" --region $REGION --targets "Id=1,Arn=$LAMBDA_ARN"
    aws lambda add-permission --function-name "$func_name" --region $REGION --statement-id "EBInvoke-$rule_name" --action "lambda:InvokeFunction" --principal "events.amazonaws.com" --source-arn "arn:aws:events:$REGION:$ACCOUNT_ID:rule/$rule_name" 2>/dev/null || true
}

setup_rule "wsc2026-ec2-stop-rule" '{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification"],"detail":{"state":["stopped"]}}' "wsc2026-ec2-stop-remediation"
setup_rule "wsc2026-ec2-terminate-rule" '{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification"],"detail":{"state":["terminated"]}}' "wsc2026-ec2-terminate-alert"
setup_rule "wsc2026-sg-change-rule" '{"source":["aws.ec2"],"detail-type":["AWS API Call via CloudTrail"],"detail":{"eventName":["AuthorizeSecurityGroupIngress"]}}' "wsc2026-sg-remediation"
setup_rule "wsc2026-role-change-rule" '{"source":["aws.iam"],"detail-type":["AWS API Call via CloudTrail"],"detail":{"eventName":["UpdateAssumeRolePolicy","PutRolePolicy","AttachRolePolicy"]}}' "wsc2026-ec2-terminate-alert"
setup_rule "wsc2026-ec2-type-change-rule" '{"source":["aws.ec2"],"detail-type":["AWS API Call via CloudTrail"],"detail":{"eventName":["ModifyInstanceAttribute"]}}' "wsc2026-ec2-terminate-alert"

aws s3 mb s3://$CONFIG_BUCKET --region $REGION 2>/dev/null || true

cat << EOF > config-bucket-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AWSConfigBucketPermissionsCheck",
      "Effect": "Allow",
      "Principal": { "Service": "config.amazonaws.com" },
      "Action": "s3:GetBucketAcl",
      "Resource": "arn:aws:s3:::$CONFIG_BUCKET"
    },
    {
      "Sid": "AWSConfigBucketDelivery",
      "Effect": "Allow",
      "Principal": { "Service": "config.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$CONFIG_BUCKET/AWSLogs/$ACCOUNT_ID/Config/*",
      "Condition": { "StringEquals": { "s3:x-amz-acl": "bucket-owner-full-control" } }
    }
  ]
}
EOF
aws s3api put-bucket-policy --bucket $CONFIG_BUCKET --policy file://config-bucket-policy.json --region $REGION

aws iam create-role --role-name wsc2026-config-role --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "config.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}' 2>/dev/null || true

aws iam attach-role-policy --role-name wsc2026-config-role --policy-arn arn:aws:iam::aws:policy/service-role/AWS_ConfigRole

sleep 15

aws configservice put-configuration-recorder \
    --configuration-recorder "{\"name\": \"default\", \"roleARN\": \"arn:aws:iam::$ACCOUNT_ID:role/wsc2026-config-role\", \"recordingGroup\": {\"allSupported\": true, \"includeGlobalResourceTypes\": true}}" \
    --region $REGION

aws configservice put-delivery-channel \
    --delivery-channel "{\"name\": \"default\", \"s3BucketName\": \"$CONFIG_BUCKET\"}" \
    --region $REGION

aws configservice start-configuration-recorder \
    --configuration-recorder-name default \
    --region $REGION

sleep 5

aws configservice put-config-rule \
    --config-rule '{
        "ConfigRuleName": "wsc2026-sg-ssh-rule",
        "Source": {
            "Owner": "AWS",
            "SourceIdentifier": "RESTRICTED_INCOMING_TRAFFIC"
        },
        "Scope": { "ComplianceResourceTypes": ["AWS::EC2::SecurityGroup"] },
        "InputParameters": "{\"blockedPort1\":\"22\"}"
    }' --region $REGION

aws configservice put-config-rule \
    --config-rule '{
        "ConfigRuleName": "wsc2026-required-tags-rule",
        "Source": {
            "Owner": "AWS",
            "SourceIdentifier": "REQUIRED_TAGS"
        },
        "Scope": { "ComplianceResourceTypes": ["AWS::EC2::Instance"] },
        "InputParameters": "{\"tag1Key\":\"Name\"}"
    }' --region $REGION

aws lambda add-permission --function-name wsc2026-sg-remediation --action lambda:InvokeFunction --statement-id config-sg --principal config.amazonaws.com --region $REGION 2>/dev/null || true
aws lambda add-permission --function-name wsc2026-tag-alert --action lambda:InvokeFunction --statement-id config-tag --principal config.amazonaws.com --region $REGION 2>/dev/null || true

aws events put-rule \
    --name "wsc2026-required-tags-rule" \
    --region $REGION \
    --event-pattern '{"source": ["aws.config"], "detail-type": ["Config Rules Compliance Change"], "detail": {"configRuleName": ["wsc2026-required-tags-rule"], "newEvaluationResult": { "complianceType": ["NON_COMPLIANT"] }}}'

TAG_LAMBDA_ARN=$(aws lambda get-function --function-name "wsc2026-tag-alert" --region $REGION --query "Configuration.FunctionArn" --output text)
aws events put-targets --rule "wsc2026-required-tags-rule" --region $REGION --targets "Id=1,Arn=$TAG_LAMBDA_ARN"

aws lambda add-permission \
    --function-name "wsc2026-tag-alert" \
    --region $REGION \
    --statement-id "AllowConfigTagToTrigger" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "arn:aws:events:$REGION:$ACCOUNT_ID:rule/wsc2026-required-tags-rule" 2>/dev/null || true

rm -f config-bucket-policy.json

echo