#!/usr/bin/env bash
set -u
export AWS_PAGER=""

OUT_TXT="asgmt2_module3_check_result.txt"
exec > >(tee "$OUT_TXT") 2>&1

for CMD in aws grep; do
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $CMD" >&2
    exit 2
  fi
done

echo "== 제2과제 3모듈 Cloud Event Handling 채점 출력 =="
echo

VPC_ID=$(aws ec2 describe-vpcs --region ap-northeast-2 --filters Name=tag:Name,Values=skills-ceh-vpc --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
SG_ID=$(aws ec2 describe-security-groups --region ap-northeast-2 --filters Name=tag:Name,Values=skills-ceh-protected-sg --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
EC2_ID=$(aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=skills-ceh-ec2 Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId | [0]' --output text 2>/dev/null || true)
TOPIC_ARN=$(aws sns list-topics --region ap-northeast-2 --query 'Topics[?contains(TopicArn, `:skills-ceh-alert-topic`)].TopicArn | [0]' --output text 2>/dev/null || true)
LAMBDA_ARN=$(aws lambda get-function-configuration --region ap-northeast-2 --function-name skills-ceh-remediate-fn --query 'FunctionArn' --output text 2>/dev/null || true)

echo "[3-1] 기본 VPC, EC2, Security Group 구성 (1.5점)"
echo "VPC_ID=${VPC_ID}"
echo "EC2_ID=${EC2_ID}"
echo "SG_ID=${SG_ID}"
aws ec2 describe-vpcs --region ap-northeast-2 --filters Name=tag:Name,Values=skills-ceh-vpc --query 'Vpcs[].{Name:Tags[?Key==`Name`].Value|[0],VpcId:VpcId,Cidr:CidrBlock}' --output table
aws ec2 describe-instances --region ap-northeast-2 --filters Name=tag:Name,Values=skills-ceh-ec2 Name=instance-state-name,Values=running --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`].Value|[0],Id:InstanceId,Type:InstanceType,State:State.Name,SecurityGroups:SecurityGroups[].GroupId}' --output table
aws ec2 describe-security-groups --region ap-northeast-2 --filters Name=tag:Name,Values=skills-ceh-protected-sg --query 'SecurityGroups[].{Name:Tags[?Key==`Name`].Value|[0],GroupId:GroupId,GroupName:GroupName,VpcId:VpcId}' --output table

echo
echo "[3-2] 보호 대상 Security Group 기준 상태 (1.5점)"
aws ec2 describe-security-groups --region ap-northeast-2 --filters Name=tag:Name,Values=skills-ceh-protected-sg --query 'SecurityGroups[].{GroupId:GroupId,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' --output json

echo
echo "[3-3] SNS Topic 및 Lambda 구성 (1.5점)"
echo "TOPIC_ARN=${TOPIC_ARN}"
aws sns list-topics --region ap-northeast-2 --query 'Topics[?contains(TopicArn, `:skills-ceh-alert-topic`)].TopicArn' --output table
aws lambda get-function-configuration --region ap-northeast-2 --function-name skills-ceh-remediate-fn --query '{FunctionName:FunctionName,State:State,LastUpdateStatus:LastUpdateStatus,Runtime:Runtime,Handler:Handler,Timeout:Timeout,Role:Role,Environment:Environment.Variables}' --output table

echo
echo "[3-4] EventBridge Rule 및 Target 구성 (1.5점)"
aws events describe-rule --region ap-northeast-2 --name skills-ceh-sg-change-rule --event-bus-name default --query '{Name:Name,State:State,EventPattern:EventPattern}' --output json
aws events list-targets-by-rule --region ap-northeast-2 --rule skills-ceh-sg-change-rule --event-bus-name default --query 'Targets[].{Id:Id,Arn:Arn}' --output table
aws lambda get-policy --region ap-northeast-2 --function-name skills-ceh-remediate-fn --query 'Policy' --output text

echo
echo "[3-5] 최종 기능 검증 (1.5점)"
echo "주의: 본 항목은 채점기준표에 따라 테스트용 Inbound 규칙 TCP/22 from 0.0.0.0/0을 임시 추가합니다."
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  echo "skills-ceh-protected-sg 식별 실패"
else
  aws ec2 revoke-security-group-ingress --region ap-northeast-2 --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  if ! aws ec2 authorize-security-group-ingress --region ap-northeast-2 --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0; then
    echo "테스트 Inbound 규칙 추가 실패"
  else
    for I in $(seq 1 36); do
      sleep 5
      echo "poll=${I}"
      aws ec2 describe-security-groups --region ap-northeast-2 --group-ids "$SG_ID" --query 'SecurityGroups[0].IpPermissions' --output json
      COUNT=$(aws ec2 describe-security-groups --region ap-northeast-2 --group-ids "$SG_ID" --query 'length(SecurityGroups[0].IpPermissions)' --output text 2>/dev/null || true)
      echo "inbound_count=${COUNT}"
      [ "$COUNT" = "0" ] && break
    done
    aws logs describe-log-groups --region ap-northeast-2 --log-group-name-prefix /aws/lambda/skills-ceh-remediate-fn --query 'logGroups[].logGroupName' --output table
    aws ec2 revoke-security-group-ingress --region ap-northeast-2 --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
  fi
fi

echo
echo "Result file: ${OUT_TXT}"
