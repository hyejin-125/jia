#!/bin/bash
set -x

REGION="ap-northeast-1"
CLIENT_VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=skills-lattice-client-vpc" --query "Vpcs[0].VpcId" --output text)
SERVICE_VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=skills-lattice-service-vpc" --query "Vpcs[0].VpcId" --output text)

CLIENT_SG_ID=$(aws ec2 describe-security-groups --region $REGION --filters "Name=group-name,Values=skills-lattice-client-assoc-sg" "Name=vpc-id,Values=$CLIENT_VPC_ID" --query "SecurityGroups[0].GroupId" --output text)
if [ -z "$CLIENT_SG_ID" ] || [ "$CLIENT_SG_ID" = "None" ]; then
    CLIENT_SG_ID=$(aws ec2 create-security-group --region $REGION \
        --group-name "skills-lattice-client-assoc-sg" \
        --description "Security group for Lattice Client VPC association" \
        --vpc-id $CLIENT_VPC_ID \
        --query "GroupId" --output text)
    
    aws ec2 authorize-security-group-ingress --region $REGION \
        --group-id $CLIENT_SG_ID \
        --protocol tcp --port 80 \
        --cidr 10.61.0.0/16
fi

SN_ID=$(aws vpc-lattice list-service-networks --region $REGION --query "items[?name=='skills-lattice-sn'].id" --output text)
if [ -z "$SN_ID" ] || [ "$SN_ID" = "None" ]; then
    SN_ID=$(aws vpc-lattice create-service-network --region $REGION \
        --name skills-lattice-sn \
        --tags "Name=skills-lattice-sn" \
        --query "id" --output text)
fi

CLIENT_ASSOC_ID=$(aws vpc-lattice create-service-network-vpc-association --region $REGION \
    --service-network-identifier $SN_ID \
    --vpc-identifier $CLIENT_VPC_ID \
    --security-group-ids $CLIENT_SG_ID \
    --tags "Name=skills-lattice-client-vpc-assoc" \
    --query "id" --output text)

echo "Waiting for Client VPC Association ($CLIENT_ASSOC_ID) to become ACTIVE..."
while true; do
    STATUS=$(aws vpc-lattice get-service-network-vpc-association --region $REGION --service-network-vpc-association-identifier "$CLIENT_ASSOC_ID" --query "status" --output text 2>/dev/null)
    if [ "$STATUS" == "ACTIVE" ]; then break; fi
    sleep 5
done

ASSOC_VPC_ID=$(aws vpc-lattice get-service-network-vpc-association --region ap-northeast-1 --service-network-vpc-association-identifier "$CLIENT_ASSOC_ID" --query 'vpcId' --output text)
echo "ASSOC_VPC_ID=${ASSOC_VPC_ID}"

NEW_SG_ID=$(aws ec2 create-security-group \
    --region ap-northeast-1 \
    --group-name "skills-lattice-assoc-sg-final" \
    --description "VPC Lattice Association SG for Associated VPC" \
    --vpc-id "$ASSOC_VPC_ID" \
    --output json | jq -r '.GroupId')

echo "SUCCESS_SG_ID: ${NEW_SG_ID}"

aws ec2 authorize-security-group-ingress \
    --region ap-northeast-1 \
    --group-id "$NEW_SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr "10.61.0.0/16"

aws vpc-lattice update-service-network-vpc-association \
    --region ap-northeast-1 \
    --service-network-vpc-association-identifier "$CLIENT_ASSOC_ID" \
    --security-group-ids "$NEW_SG_ID"

SERVICE_ASSOC_ID=$(aws vpc-lattice create-service-network-vpc-association --region $REGION \
    --service-network-identifier $SN_ID \
    --vpc-identifier $SERVICE_VPC_ID \
    --tags "Name=skills-lattice-service-vpc-assoc" \
    --query "id" --output text)

echo "Waiting for Service VPC Association ($SERVICE_ASSOC_ID) to become ACTIVE..."
while true; do
    STATUS=$(aws vpc-lattice get-service-network-vpc-association --region $REGION --service-network-vpc-association-identifier "$SERVICE_ASSOC_ID" --query "status" --output text 2>/dev/null)
    if [ "$STATUS" == "ACTIVE" ]; then break; fi
    sleep 5
done

TG_CONFIG="{\"port\":8080,\"protocol\":\"HTTP\",\"vpcIdentifier\":\"$SERVICE_VPC_ID\",\"healthCheck\":{\"enabled\":true,\"path\":\"/health\",\"protocol\":\"HTTP\"}}"

TG_ID=$(aws vpc-lattice create-target-group --region $REGION \
    --name skills-lattice-order-tg \
    --type INSTANCE \
    --config "$TG_CONFIG" \
    --tags "Name=skills-lattice-order-tg" \
    --query "id" --output text)

SERVICE_ID=$(aws vpc-lattice create-service --region $REGION \
    --name skills-lattice-order-service \
    --tags "Name=skills-lattice-order-service" \
    --query "id" --output text)

while true; do
    STATUS=$(aws vpc-lattice get-service --region $REGION --service-identifier "$SERVICE_ID" --query "status" --output text 2>/dev/null)
    if [ "$STATUS" == "ACTIVE" ]; then break; fi
    sleep 5
done

ASSOC_ID=$(aws vpc-lattice create-service-network-service-association --region $REGION \
    --service-network-identifier $SN_ID \
    --service-identifier $SERVICE_ID \
    --tags "Name=skills-lattice-order-service-assoc" \
    --query "id" --output text)

echo "Waiting for Service Network Service Association ($ASSOC_ID) to become ACTIVE..."
while true; do
    STATUS=$(aws vpc-lattice get-service-network-service-association --region $REGION --service-network-service-association-identifier "$ASSOC_ID" --query "status" --output text 2>/dev/null)
    if [ "$STATUS" == "ACTIVE" ]; then break; fi
    sleep 5
done

DEFAULT_ACTION="{\"forward\":{\"targetGroups\":[{\"targetGroupIdentifier\":\"$TG_ID\",\"weight\":100}]}}"
LISTENER_ID=$(aws vpc-lattice create-listener --region $REGION \
    --service-identifier $SERVICE_ID \
    --name skills-lattice-http-listener \
    --protocol HTTP \
    --port 80 \
    --default-action "$DEFAULT_ACTION" \
    --tags "Name=skills-lattice-http-listener" \
    --query "id" --output text)
echo