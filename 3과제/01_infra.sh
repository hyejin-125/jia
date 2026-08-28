cat > 01_infra.sh <<'EOF'
#!/bin/bash
set -e

REGION="ap-northeast-2"
CLUSTER="apdev-eks"
NODEGROUP="apdev-node"
VPC_CIDR="10.20.0.0/16"

DB_ID="apdev-rds-instance"
DB_NAME="dev"
DB_USER="admin"

echo "=========================================="
echo " APDEV INFRASTRUCTURE"
echo "=========================================="

aws configure set default.region "$REGION"

echo "[1] EKS"

cat > eksctl.yaml <<EKS
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER}
  region: ${REGION}

managedNodeGroups:
  - name: ${NODEGROUP}
    instanceType: t3.medium
    desiredCapacity: 1
    minSize: 1
    maxSize: 1

    volumeSize: 30
    volumeType: gp3

    labels:
      role: app

    tags:
      Name: ${NODEGROUP}
      Project: apdev

vpc:
  cidr: ${VPC_CIDR}
  nat:
    gateway: Single
EKS

if aws eks describe-cluster \
    --name "$CLUSTER" \
    --region "$REGION" >/dev/null 2>&1
then
    echo "EKS already exists"
else
    eksctl create cluster -f eksctl.yaml
fi

echo "[2] kubeconfig"

aws eks update-kubeconfig \
    --region "$REGION" \
    --name "$CLUSTER"

echo "[3] ECR"

for APP in user product stress
do
    REPO="apdev-${APP}"

    if aws ecr describe-repositories \
        --repository-names "$REPO" \
        --region "$REGION" >/dev/null 2>&1
    then
        echo "$REPO exists"
    else
        aws ecr create-repository \
            --repository-name "$REPO" \
            --region "$REGION"
    fi
done

echo "[4] VPC ID"

VPC_ID=$(aws eks describe-cluster \
    --name "$CLUSTER" \
    --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text)

echo "VPC = $VPC_ID"

echo "[5] RDS Security Group"

RDS_SG_ID=$(aws ec2 describe-security-groups \
    --filters \
      "Name=group-name,Values=apdev-rds-sg" \
      "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

if [ "$RDS_SG_ID" = "None" ] || [ -z "$RDS_SG_ID" ]
then
    RDS_SG_ID=$(aws ec2 create-security-group \
        --group-name apdev-rds-sg \
        --description "APDEV RDS SG" \
        --vpc-id "$VPC_ID" \
        --query GroupId \
        --output text)

    aws ec2 create-tags \
        --resources "$RDS_SG_ID" \
        --tags Key=Name,Value=apdev-rds-sg
fi

echo "RDS SG = $RDS_SG_ID"

echo "[6] RDS inbound"

NODE_SG_ID=$(aws eks describe-cluster \
    --name "$CLUSTER" \
    --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
    --output text)

aws ec2 authorize-security-group-ingress \
    --group-id "$RDS_SG_ID" \
    --protocol tcp \
    --port 3306 \
    --source-group "$NODE_SG_ID" \
    2>/dev/null || true

echo "[7] DB subnet group"

SUBNET_GROUP="apdev-db-subnet"

SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].SubnetId' \
    --output text)

if aws rds describe-db-subnet-groups \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --region "$REGION" >/dev/null 2>&1
then
    echo "DB subnet group exists"
else

    aws rds create-db-subnet-group \
        --db-subnet-group-name "$SUBNET_GROUP" \
        --db-subnet-group-description "APDEV DB subnet" \
        --subnet-ids $SUBNET_IDS \
        --region "$REGION"

fi

echo ""
echo "=========================================="
echo " RDS PASSWORD"
echo "=========================================="

read -s -p "RDS password: " DB_PASSWORD
echo ""

echo "[8] RDS"

if aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" \
    --region "$REGION" >/dev/null 2>&1
then

    echo "RDS already exists"

else

    aws rds create-db-instance \
        --db-instance-identifier "$DB_ID" \
        --db-instance-class db.t3.micro \
        --engine mysql \
        --engine-version 8.0 \
        --allocated-storage 20 \
        --storage-type gp3 \
        --master-username "$DB_USER" \
        --master-user-password "$DB_PASSWORD" \
        --db-name "$DB_NAME" \
        --db-subnet-group-name "$SUBNET_GROUP" \
        --vpc-security-group-ids "$RDS_SG_ID" \
        --multi-az \
        --backup-retention-period 1 \
        --no-publicly-accessible \
        --region "$REGION"

fi

echo "[9] S3"

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account \
    --output text)

BUCKET="apdev-product-images-${ACCOUNT_ID}"

if aws s3api head-bucket \
    --bucket "$BUCKET" 2>/dev/null
then
    echo "S3 exists"
else
    aws s3api create-bucket \
        --bucket "$BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration \
        LocationConstraint="$REGION"
fi

echo ""
echo "=========================================="
echo " INFRA COMPLETE"
echo "=========================================="

echo "Cluster : $CLUSTER"
echo "VPC     : $VPC_ID"
echo "RDS     : $DB_ID"
echo "S3      : $BUCKET"
echo "Node    : t3.medium x 1"

echo ""
echo "Waiting RDS..."

aws rds wait db-instance-available \
    --db-instance-identifier "$DB_ID" \
    --region "$REGION"

echo ""
echo "RDS READY"

aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" \
    --region "$REGION" \
    --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address,DBInstanceClass,Engine,MultiAZ]' \
    --output table
EOF

chmod +x 01_infra.sh
./01_infra.sh
