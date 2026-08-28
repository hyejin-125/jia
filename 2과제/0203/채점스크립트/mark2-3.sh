#!/bin/bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "ACCOUNT ID: $ACCOUNT_ID"
aws configure set region eu-west-1

INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=wsc2026-event-ec2" "Name=instance-state-name,Values=running,stopped" --query "Reservations[0].Instances[0].InstanceId" --output text)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wsc2026-event-sg" --query "SecurityGroups[0].GroupId" --output text)

# === Trigger EC2 stop + SG add ===
aws ec2 stop-instances --instance-ids $INSTANCE_ID &>/dev/null
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 &>/dev/null

# 3-1 SNS + Lambda
echo ====================
echo "  3-1 SNS + Lambda"
echo ====================
aws sns get-topic-attributes --topic-arn arn:aws:sns:eu-west-1:${ACCOUNT_ID}:wsc2026-event-alert --query "Attributes.TopicArn" --output text; for fn in wsc2026-ec2-stop-remediation wsc2026-ec2-terminate-alert wsc2026-sg-remediation wsc2026-tag-alert; do aws lambda get-function --function-name $fn --query "Configuration.[FunctionName,Runtime]" --output text; done

# 3-2 EventBridge Rules
echo ====================
echo "  3-2 EventBridge Rules"
echo ====================
for rule in wsc2026-ec2-stop-rule wsc2026-ec2-terminate-rule; do echo "$rule -> $(aws events list-targets-by-rule --rule $rule --query "Targets[0].Arn" --output text)"; done

# 3-3 AWS Config Rules
echo ====================
echo "  3-3 AWS Config Rules"
echo ====================
aws configservice describe-config-rules --config-rule-names wsc2026-sg-ssh-rule wsc2026-required-tags-rule --query "ConfigRules[*].[ConfigRuleName,ConfigRuleState]" --output text

# 3-4 Remediation Test
echo ====================
echo "  3-4 Remediation Test"
echo ====================
sleep 30; echo "EC2 State (expect running): $(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].State.Name" --output text)"; echo "SG Inbound Count (expect 0): $(aws ec2 describe-security-groups --group-ids $SG_ID --query "SecurityGroups[0].IpPermissions | length(@)" --output text)"

# 3-5 Tag Compliance
echo ====================
echo "  3-5 Tag Compliance"
echo ====================
aws configservice get-compliance-details-by-config-rule --config-rule-name wsc2026-required-tags-rule --compliance-types NON_COMPLIANT --query "EvaluationResults[0].EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId" --output text
