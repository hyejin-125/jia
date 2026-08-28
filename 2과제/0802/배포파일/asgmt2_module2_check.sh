#!/usr/bin/env bash
set -u
export AWS_PAGER=""

OUT_TXT="asgmt2_module2_check_result.txt"
exec > >(tee "$OUT_TXT") 2>&1

for CMD in aws curl; do
  if ! command -v "$CMD" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $CMD" >&2
    exit 2
  fi
done

echo "== 제2과제 2모듈 Simplify Service Networking with VPC Lattice 채점 출력 =="
echo

echo "[2-1] 기본 VPC 구성 (1.5점)"
aws ec2 describe-vpcs --region ap-northeast-1 --filters Name=tag:Name,Values=skills-lattice-client-vpc,skills-lattice-service-vpc --query 'Vpcs[].{Name:Tags[?Key==`Name`].Value|[0],VpcId:VpcId,Cidr:CidrBlock,State:State}' --output table

echo
echo "[2-2] Client/Service EC2 및 애플리케이션 구성 (1.5점)"
aws ec2 describe-instances --region ap-northeast-1 --filters Name=tag:Name,Values=skills-lattice-client-ec2,skills-lattice-service-ec2 Name=instance-state-name,Values=running --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`].Value|[0],Id:InstanceId,Type:InstanceType,PublicIp:PublicIpAddress,PrivateIp:PrivateIpAddress,State:State.Name}' --output table
CLIENT_IP=$(aws ec2 describe-instances --region ap-northeast-1 --filters Name=tag:Name,Values=skills-lattice-client-ec2 Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || true)
echo "CLIENT_IP=${CLIENT_IP}"
if [ -n "$CLIENT_IP" ] && [ "$CLIENT_IP" != "None" ]; then
  curl -s -m 10 "http://${CLIENT_IP}/health"; echo
else
  echo "Client EC2 Public IP 식별 실패"
fi

SERVICE_NETWORK_ID=$(aws vpc-lattice list-service-networks --region ap-northeast-1 --query 'items[?name==`skills-lattice-sn`].id|[0]' --output text 2>/dev/null || true)
SERVICE_ID=$(aws vpc-lattice list-services --region ap-northeast-1 --query 'items[?name==`skills-lattice-order-service`].id|[0]' --output text 2>/dev/null || true)
TARGET_GROUP_ID=$(aws vpc-lattice list-target-groups --region ap-northeast-1 --query 'items[?name==`skills-lattice-order-tg`].id|[0]' --output text 2>/dev/null || true)
echo
echo "[2-3] VPC Lattice Service Network 및 Service 구성 (1.5점)"
echo "SERVICE_NETWORK_ID=${SERVICE_NETWORK_ID}"
echo "SERVICE_ID=${SERVICE_ID}"
aws vpc-lattice list-service-networks --region ap-northeast-1 --query 'items[?name==`skills-lattice-sn`].{Name:name,Id:id,Status:status}' --output table
aws vpc-lattice list-services --region ap-northeast-1 --query 'items[?name==`skills-lattice-order-service`].{Name:name,Id:id,Dns:dnsEntry.domainName,Status:status}' --output table
aws vpc-lattice list-service-network-vpc-associations --region ap-northeast-1 --service-network-identifier "$SERVICE_NETWORK_ID" --query 'items[].{VpcId:vpcId,Status:status}' --output table
aws vpc-lattice list-service-network-service-associations --region ap-northeast-1 --service-network-identifier "$SERVICE_NETWORK_ID" --query 'items[].{ServiceId:serviceId,Status:status,Dns:dnsEntry.domainName}' --output table

echo
echo "[2-4] Target Group, Listener, Security Group 구성 (1.5점)"
echo "TARGET_GROUP_ID=${TARGET_GROUP_ID}"
aws vpc-lattice list-target-groups --region ap-northeast-1 --query 'items[?name==`skills-lattice-order-tg`].{Name:name,Id:id,Type:type,Port:port,Protocol:protocol,Vpc:vpcIdentifier,Status:status}' --output table
aws vpc-lattice list-targets --region ap-northeast-1 --target-group-identifier "$TARGET_GROUP_ID" --query 'items[].{Target:id,Port:port,Status:status}' --output table
aws vpc-lattice list-listeners --region ap-northeast-1 --service-identifier "$SERVICE_ID" --query 'items[?name==`skills-lattice-http-listener`].{Name:name,Id:id,Port:port,Protocol:protocol}' --output table
aws ec2 describe-security-groups --region ap-northeast-1 --filters Name=tag:Name,Values=skills-lattice-service-sg --query 'SecurityGroups[].{GroupId:GroupId,Inbound:IpPermissions}' --output json

echo
echo "[2-5] End-to-End 기능 검증 (1.5점)"
if [ -n "$CLIENT_IP" ] && [ "$CLIENT_IP" != "None" ]; then
  curl -s -m 10 "http://${CLIENT_IP}/v1/client/orders?id=1001"; echo
else
  echo "Client EC2 Public IP 식별 실패"
fi

echo
echo "Result file: ${OUT_TXT}"
