#!/bin/bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "ACCOUNT ID: $ACCOUNT_ID"
aws configure set region ap-northeast-1

read -p "비번호: " NUM
BUCKET_NAME="wsc2026-sensor-alert-bucket-${NUM}"
CLUSTER_ARN=$(aws kafka list-clusters --cluster-name-filter wsc2026-msk-cluster --query "ClusterInfoList[0].ClusterArn" --output text)

# 4-1 DynamoDB + S3
echo ====================
echo "  4-1 DynamoDB + S3"
echo ====================
aws dynamodb describe-table --table-name wsc2026-sensor-data --query "Table.[TableName,KeySchema[*].AttributeName]" --output text && aws s3api head-bucket --bucket $BUCKET_NAME 2>&1

# 4-2 Lambda Functions
echo ====================
echo "  4-2 Lambda Functions"
echo ====================
for fn in wsc2026-sensor-consumer wsc2026-sensor-alert-consumer; do aws lambda get-function --function-name $fn --query "Configuration.[FunctionName,Runtime]" --output text; done

# 4-3 MSK Cluster
echo ====================
echo "  4-3 MSK Cluster"
echo ====================
aws kafka describe-cluster --cluster-arn $CLUSTER_ARN --query "ClusterInfo.[ClusterName,State,CurrentBrokerSoftwareInfo.KafkaVersion,BrokerNodeGroupInfo.InstanceType,ClientAuthentication.Sasl.Iam.Enabled]" --output text

# 4-4 MSK Trigger
echo ====================
echo "  4-4 MSK Trigger"
echo ====================
for fn in wsc2026-sensor-consumer wsc2026-sensor-alert-consumer; do aws lambda list-event-source-mappings --function-name $fn --query "EventSourceMappings[0].[State]" --output text; done

# 4-5-A Data Processing
echo ====================
echo "  4-5-A Data Processing"
echo ====================
aws dynamodb scan --table-name wsc2026-sensor-data --max-items 1 --query "Items[0].{sensorId:sensorId.S,temperature:temperature.S,status:status.S}" --output json

# 4-5-B Producer Running
echo ====================
echo "  4-5-B Producer Running"
echo ====================
aws dynamodb scan --table-name wsc2026-sensor-data --max-items 3 --query "Items[*].{sensorId:sensorId.S,timestamp:timestamp.S}" --output table
