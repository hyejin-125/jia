#!/bin/bash
set -x

rm -rf ~/.aws
if [[ -z "${EXAM_NO:-}" || "${EXAM_NO}" == "<비번호>" || "${EXAM_NO}" == "<exam-number>" ]]; then
  echo "[오류] 비번호(EXAM_NO)가 제대로 설정되지 않았습니다." >&2
  exit 1
fi


export AWS_DEFAULT_REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "ACCOUNT_ID=${ACCOUNT_ID}, AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}"

VPC_NAME="msk-vpc"
VPC_CIDR="192.168.0.0/16"
PUB_A_CIDR="192.168.0.0/24"; PUB_B_CIDR="192.168.1.0/24"
PRIV_A_CIDR="192.168.10.0/24"; PRIV_B_CIDR="192.168.11.0/24"
AZ_A="${AZ_A:-ap-northeast-1a}"; AZ_B="${AZ_B:-ap-northeast-1c}"

PUB_A_NAME="msk-pub-a"; PUB_B_NAME="msk-pub-b"
PRIV_A_NAME="msk-priv-a"; PRIV_B_NAME="msk-priv-b"
PUB_RTB_NAME="msk-pub-rtb"; PRIV_A_RTB_NAME="msk-priv-a-rtb"; PRIV_B_RTB_NAME="msk-priv-b-rtb"

MSK_CLUSTER_NAME="wsc2026-msk-cluster"
TABLE_NAME="wsc2026-sensor-data"
BUCKET_NAME="wsc2026-sensor-alert-bucket-${EXAM_NO}"
SNS_TOPIC_NAME="wsc2026-sensor-alert"
SNS_TOPIC_ARN="arn:aws:sns:${AWS_DEFAULT_REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}"

EC2_ROLE_NAME="wsc2026-msk-ec2-role"; EC2_PROFILE_NAME="wsc2026-msk-ec2-profile"
LAMBDA_ROLE_NAME="wsc2026-msk-lambda-role"
MSK_SG_NAME="wsc2026-msk-sg"; PRODUCER_SG_NAME="wsc2026-sensor-producer-sg"; LAMBDA_SG_NAME="wsc2026-msk-lambda-sg"

ensure_vpc() {
  local vpc_id=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${VPC_NAME}" --query "Vpcs[0].VpcId" --output text)
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    vpc_id=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --query "Vpc.VpcId" --output text)
    aws ec2 create-tags --resources "$vpc_id" --tags Key=Name,Value="$VPC_NAME"
  fi
  aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-hostnames '{"Value":true}'
  echo "$vpc_id"
}

ensure_subnet() {
  local vpc_id="$1" name="$2" cidr="$3" az="$4" public_flag="${5:-false}"
  local subnet_id=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=${name}" --query "Subnets[0].SubnetId" --output text)
  if [[ -z "$subnet_id" || "$subnet_id" == "None" ]]; then
    subnet_id=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block "$cidr" --availability-zone "$az" --query "Subnet.SubnetId" --output text)
    aws ec2 create-tags --resources "$subnet_id" --tags Key=Name,Value="$name"
    [[ "$public_flag" == "true" ]] && aws ec2 modify-subnet-attribute --subnet-id "$subnet_id" --map-public-ip-on-launch
  fi
  echo "$subnet_id"
}

ensure_igw() {
  local vpc_id="$1" 
  local igw_id=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${vpc_id}" --query "InternetGateways[0].InternetGatewayId" --output text)
  if [[ -z "$igw_id" || "$igw_id" == "None" ]]; then
    igw_id=$(aws ec2 create-internet-gateway --query "InternetGateway.InternetGatewayId" --output text)
    aws ec2 create-tags --resources "$igw_id" --tags Key=Name,Value=msk-igw
    aws ec2 attach-internet-gateway --vpc-id "$vpc_id" --internet-gateway-id "$igw_id"
  fi
  echo "$igw_id"
}

ensure_nat() {
  local pub_subnet="$1" 
  local nat_id=$(aws ec2 describe-nat-gateways --filter "Name=subnet-id,Values=${pub_subnet}" "Name=state,Values=available,pending" --query "NatGateways[0].NatGatewayId" --output text)
  if [[ -z "$nat_id" || "$nat_id" == "None" ]]; then
    local alloc_id=$(aws ec2 allocate-address --domain vpc --query "AllocationId" --output text)
    nat_id=$(aws ec2 create-nat-gateway --subnet-id "$pub_subnet" --allocation-id "$alloc_id" --query "NatGateway.NatGatewayId" --output text)
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$nat_id"
  fi
  aws ec2 create-tags --resources "$nat_id" --tags Key=Name,Value=msk-ngw
  echo "$nat_id"
}

ensure_rtb() {
  local vpc_id="$1" name="$2" 
  local rtb_id=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=${name}" --query "RouteTables[0].RouteTableId" --output text)
  if [[ -z "$rtb_id" || "$rtb_id" == "None" ]]; then
    rtb_id=$(aws ec2 create-route-table --vpc-id "$vpc_id" --query "RouteTable.RouteTableId" --output text)
    aws ec2 create-tags --resources "$rtb_id" --tags Key=Name,Value="$name"
  fi
  echo "$rtb_id"
}

ensure_route_assoc() {
  local subnet_id="$1" rtb_id="$2" 
  local current_rtb=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${subnet_id}" --query "RouteTables[0].RouteTableId" --output text)
  [[ "$current_rtb" == "$rtb_id" ]] && return 0
  local assoc_id=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${subnet_id}" --query "RouteTables[0].Associations[?SubnetId=='${subnet_id}'].RouteTableAssociationId|[0]" --output text)
  if [[ -n "$assoc_id" && "$assoc_id" != "None" ]]; then
    aws ec2 replace-route-table-association --association-id "$assoc_id" --route-table-id "$rtb_id" >/dev/null
  else
    aws ec2 associate-route-table --subnet-id "$subnet_id" --route-table-id "$rtb_id" >/dev/null
  fi
}

ensure_sg() {
  local vpc_id="$1" name="$2" desc="$3" 
  local sg_id=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${name}" --query "SecurityGroups[0].GroupId" --output text)
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id=$(aws ec2 create-security-group --group-name "$name" --description "$desc" --vpc-id "$vpc_id" --query "GroupId" --output text)
    aws ec2 create-tags --resources "$sg_id" --tags Key=Name,Value="$name"
  fi
  echo "$sg_id"
}

VPC_ID=$(ensure_vpc)
PUB_A=$(ensure_subnet "$VPC_ID" "$PUB_A_NAME" "$PUB_A_CIDR" "$AZ_A" true)
PUB_B=$(ensure_subnet "$VPC_ID" "$PUB_B_NAME" "$PUB_B_CIDR" "$AZ_B" true)
PRIV_A=$(ensure_subnet "$VPC_ID" "$PRIV_A_NAME" "$PRIV_A_CIDR" "$AZ_A" false)
PRIV_B=$(ensure_subnet "$VPC_ID" "$PRIV_B_NAME" "$PRIV_B_CIDR" "$AZ_B" false)
IGW_ID=$(ensure_igw "$VPC_ID")
NAT_ID=$(ensure_nat "$PUB_A")
PUB_RTB=$(ensure_rtb "$VPC_ID" "$PUB_RTB_NAME"); PRIV_A_RTB=$(ensure_rtb "$VPC_ID" "$PRIV_A_RTB_NAME"); PRIV_B_RTB=$(ensure_rtb "$VPC_ID" "$PRIV_B_RTB_NAME")
aws ec2 create-route --route-table-id "$PUB_RTB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null 2>&1 || true
aws ec2 create-route --route-table-id "$PRIV_A_RTB" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null 2>&1 || true
aws ec2 create-route --route-table-id "$PRIV_B_RTB" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null 2>&1 || true
ensure_route_assoc "$PUB_A" "$PUB_RTB"; ensure_route_assoc "$PUB_B" "$PUB_RTB"
ensure_route_assoc "$PRIV_A" "$PRIV_A_RTB"; ensure_route_assoc "$PRIV_B" "$PRIV_B_RTB"

MSK_SG=$(ensure_sg "$VPC_ID" "$MSK_SG_NAME" "Access to MSK brokers")
PRODUCER_SG=$(ensure_sg "$VPC_ID" "$PRODUCER_SG_NAME" "Security group for sensor producer EC2")
LAMBDA_SG=$(ensure_sg "$VPC_ID" "$LAMBDA_SG_NAME" "Security group for sensor consumer lambdas")
aws ec2 authorize-security-group-ingress --group-id "$MSK_SG" --ip-permissions "IpProtocol=tcp,FromPort=9098,ToPort=9098,UserIdGroupPairs=[{GroupId=$PRODUCER_SG},{GroupId=$LAMBDA_SG}]" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$MSK_SG" --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$MSK_SG}]" >/dev/null 2>&1 || true

aws s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1 || aws s3api create-bucket --bucket "$BUCKET_NAME" --create-bucket-configuration "LocationConstraint=${AWS_DEFAULT_REGION}" >/dev/null
aws sns get-topic-attributes --topic-arn "$SNS_TOPIC_ARN" >/dev/null 2>&1 || aws sns create-topic --name "$SNS_TOPIC_NAME" >/dev/null
aws dynamodb describe-table --table-name "$TABLE_NAME" >/dev/null 2>&1 || aws dynamodb create-table --table-name "$TABLE_NAME" --attribute-definitions AttributeName=sensorId,AttributeType=S AttributeName=timestamp,AttributeType=S --key-schema AttributeName=sensorId,KeyType=HASH AttributeName=timestamp,KeyType=RANGE --billing-mode PAY_PER_REQUEST >/dev/null

cat > /tmp/ec2-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
aws iam get-role --role-name "$EC2_ROLE_NAME" >/dev/null 2>&1 || aws iam create-role --role-name "$EC2_ROLE_NAME" --assume-role-policy-document file:///tmp/ec2-trust.json >/dev/null
aws iam attach-role-policy --role-name "$EC2_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null || true
cat > /tmp/ec2-inline.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["kafka:GetBootstrapBrokers","kafka:DescribeCluster","kafka:DescribeClusterV2","kafka-cluster:*"],"Resource":"*"}]}
JSON
aws iam put-role-policy --role-name "$EC2_ROLE_NAME" --policy-name wsc2026-msk-ec2-inline --policy-document file:///tmp/ec2-inline.json >/dev/null
aws iam get-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" >/dev/null 2>&1 || aws iam create-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$EC2_PROFILE_NAME" --role-name "$EC2_ROLE_NAME" >/dev/null 2>&1 || true

cat > /tmp/lambda-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1 || aws iam create-role --role-name "$LAMBDA_ROLE_NAME" --assume-role-policy-document file:///tmp/lambda-trust.json >/dev/null
for p in AWSLambdaBasicExecutionRole AWSLambdaVPCAccessExecutionRole AWSLambdaMSKExecutionRole; do
  aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/service-role/${p}" >/dev/null || true
done
cat > /tmp/lambda-inline.json <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ec2:DescribeSecurityGroups","ec2:DescribeSubnets","ec2:DescribeVpcs"],"Resource":"*"},{"Effect":"Allow","Action":["dynamodb:PutItem","dynamodb:GetItem","dynamodb:UpdateItem","dynamodb:Scan"],"Resource":"arn:aws:dynamodb:${AWS_DEFAULT_REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"},{"Effect":"Allow","Action":["sns:Publish"],"Resource":"${SNS_TOPIC_ARN}"},{"Effect":"Allow","Action":["s3:PutObject"],"Resource":"arn:aws:s3:::${BUCKET_NAME}/*"},{"Effect":"Allow","Action":["kafka:GetBootstrapBrokers","kafka:DescribeCluster","kafka:DescribeClusterV2","kafka-cluster:*"],"Resource":"*"}]}
JSON
aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name wsc2026-msk-lambda-inline --policy-document file:///tmp/lambda-inline.json >/dev/null

CLUSTER_ARN=$(aws kafka list-clusters-v2 --cluster-name-filter "$MSK_CLUSTER_NAME" --query "ClusterInfoList[0].ClusterArn" --output text)
if [[ -z "$CLUSTER_ARN" || "$CLUSTER_ARN" == "None" ]]; then
  CLUSTER_ARN=$(aws kafka create-cluster \
    --cluster-name "$MSK_CLUSTER_NAME" \
    --kafka-version "3.6.0" \
    --number-of-broker-nodes 2 \
    --broker-node-group-info "InstanceType=kafka.t3.small,ClientSubnets=${PRIV_A},${PRIV_B},SecurityGroups=${MSK_SG}" \
    --client-authentication "Sasl={Iam={Enabled=true}}" \
    --encryption-info "EncryptionInTransit={ClientBroker=TLS,InCluster=true}" \
    --query "ClusterArn" --output text)
  echo "MSK ARN: ${CLUSTER_ARN}"
else
  echo "기존 MSK: ${CLUSTER_ARN}"
fi