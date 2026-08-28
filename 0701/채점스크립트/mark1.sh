#!/bin/bash

echo "Module 1 - NoSQL"
export AWS_ACCESS_KEY_ID=""
export AWS_SECRET_ACCESS_KEY=""
rm -rf ~/.aws
aws sts get-caller-identity | jq .Account
echo "채점준비 끝! 채점 시작!"

echo "\n=== 1-1-A ==="

aws dynamodb describe-table \
  --table-name bigbae-nosql-reservation-table \
  --region ap-southeast-1 \
  | jq -r '
      "TableName " + .Table.TableName,
      (.Table.KeySchema[] | "KEY " + .KeyType + " " + .AttributeName),
      (.Table.AttributeDefinitions[] | "Attribute " + .AttributeName + " " + .AttributeType),
      "Stream " + .Table.StreamSpecification.StreamViewType,
      "Billing Mode " + .Table.BillingModeSummary.BillingMode'
aws dynamodb describe-continuous-backups \
  --table-name bigbae-nosql-reservation-table \
  --region ap-southeast-1 \
  | jq -r '"PITR " + .ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus'

echo "\n=== 1-2-A ==="

aws dynamodb describe-table \
  --table-name bigbae-nosql-reservation-table \
  --region ap-southeast-1 \
  | jq -r '.Table.GlobalSecondaryIndexes[] |
      "GSI Name " + .IndexName,
      (.KeySchema[] | "GSI Key " + .KeyType + " " + .AttributeName),
      "GSI Projection " + .Projection.ProjectionType'
aws dynamodb describe-table \
  --table-name bigbae-nosql-audit-table \
  --region ap-southeast-1 \
  | jq -r '
      "Audit Table Name " + .Table.TableName,
      (.Table.KeySchema[] | "Audit Key " + .KeyType + " " + .AttributeName)'

echo "\n=== 1-3-A ==="
aws lambda get-function \
  --function-name bigbae-nosql-reservation-audit \
  --region ap-southeast-1 \
  | jq -r '
      "Lambda Name " + .Configuration.FunctionName,
      "Lambda Runtime " + .Configuration.Runtime,
      "Lambda Timeout " + (.Configuration.Timeout | tostring)'
aws lambda list-event-source-mappings \
  --function-name bigbae-nosql-reservation-audit \
  --region ap-southeast-1 \
  | jq -r '.EventSourceMappings[] |
      "Event Source Mapping Source " + (.EventSourceArn | split("/")[1]),
      "Event Source Mapping State " + .State'

echo "\n=== 1-4-A ==="
EC2_IP=$(aws ec2 describe-instances \
  --region ap-southeast-1 \
  --filters "Name=tag:Name,Values=bigbae-nosql-app-ec2" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].PublicIpAddress" \
  --output text)
echo "EC2 IP " + ${EC2_IP}
curl -s --max-time 10 -o /dev/null \
  -w "healthcheck %{http_code}\n" \
  "http://${EC2_IP}:8080/healthcheck"

echo "\n=== 1-5-A ==="

I=$(aws ec2 describe-instances --region ap-southeast-1 --filters Name=tag:Name,Values=bigbae-nosql-app-ec2 Name=instance-state-name,Values=running --query Reservations[].Instances[].PublicIpAddress --output text)
T=train-$(date +%s) S=A1 U=user1 V=user2
R(){ curl -s -w" %{http_code}" -X POST http://$I:8080/$1 -H Content-Type:application/json -d "{\"train_id\":\"$T\",\"seat_id\":\"$S\",\"user_id\":\"$2\"}"; echo; }
R reserve $U; R reserve $V; R cancel $V; R cancel $U

echo "\n=== 1-6-A ==="
I=$(aws ec2 describe-instances --region ap-southeast-1 --filters Name=tag:Name,Values=bigbae-nosql-app-ec2 Name=instance-state-name,Values=running --query Reservations[].Instances[].PublicIpAddress --output text)
T=train-$(date +%s) S=B1 U=usr1
P(){ curl -s -X POST http://$I:8080/$1 -H Content-Type:application/json -d "{\"train_id\":\"$T\",\"seat_id\":\"$S\",\"user_id\":\"$U\"}" >/dev/null; }
A(){ aws dynamodb scan --table-name bigbae-nosql-audit-table --region ap-southeast-1|jq "[.Items[]|select(.train_id.S==\"$T\" and .seat_id.S==\"$S\")]|length"; }
P reserve
curl -s http://$I:8080/my-bookings/$U|jq "[.[]|select(.train_id==\"$T\" and .seat_id==\"$S\")]|length"
curl -s http://$I:8080/seats/$T|jq "[.[]|select(.seat_id==\"$S\")]|[.[0].status,.[0].user_id==\"$U\"]"
sleep 30;A
P cancel
curl -s http://$I:8080/my-bookings/$U|jq "[.[]|select(.train_id==\"$T\" and .seat_id==\"$S\")]|length"
sleep 30;A