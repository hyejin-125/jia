#!/bin/bash

echo "Task 1 Marking"
# export AWS_ACCESS_KEY_ID=""
# export AWS_SECRET_ACCESS_KEY=""
# rm -rf ~/.aws
# aws sts get-caller-identity | jq .Account
echo "채점준비 끝! 채점 시작!"

echo "=== 1-1-A ==="
aws ec2 describe-vpcs --filters Name=tag:Name,Values=unicorn-vpc --query "Vpcs[].CidrBlock" --output json
aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-pub-a,unicorn-subnet-pub-b,unicorn-subnet-pub-c --query "Subnets[].CidrBlock" --output text
aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-a,unicorn-subnet-priv-b,unicorn-subnet-priv-c --query "Subnets[].CidrBlock" --output text

echo "=== 1-2-A ==="
aws ec2 describe-route-tables --filters Name=tag:Name,Values=unicorn-rt-pub --query "RouteTables[0].[Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId, length(Associations[?SubnetId!=null])]" --output text
aws ec2 describe-route-tables --filters Name=tag:Name,Values=unicorn-rt-priv-a,unicorn-rt-priv-b,unicorn-rt-priv-c --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId" --output text


echo "=== 1-3-A ==="
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=unicorn-vpc --query "Vpcs[0].VpcId" --output text)
aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID --query "VpcEndpoints[].ServiceName" --output json
aws ec2 describe-flow-logs --filter Name=resource-id,Values=$VPC_ID --query "length(FlowLogs)" --output text

echo "=== 2-1-A ==="
for a in app data platform; do
  aws kms get-key-rotation-status --key-id $(aws kms describe-key --key-id alias/unicorn-kms-$a --query "KeyMetadata.KeyId" --output text) --query "[KeyRotationEnabled, RotationPeriodInDays]" --output text
done

echo "=== 3-1-A ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET=unicorn-web-$ACCOUNT_ID
aws s3api list-buckets --query "Buckets[?contains(Name, 'unicorn-web-')].Name" | jq -r '.[]'
aws s3api get-public-access-block --bucket $BUCKET --query "PublicAccessBlockConfiguration" --output json | jq -r 'to_entries | map(.value) | @tsv'
aws s3api get-bucket-versioning --bucket $BUCKET --query "Status" --output text
aws s3api get-bucket-encryption --bucket $BUCKET --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.[SSEAlgorithm, KMSMasterKeyID]" --output text

echo "=== 4-1-A ==="
aws dynamodb describe-table --table-name unicorn-concert-db --query "Table.{Billing:BillingModeSummary.BillingMode, PK:KeySchema[?KeyType=='HASH'].AttributeName|[0], GSIName:GlobalSecondaryIndexes[0].IndexName, GSI_PK:GlobalSecondaryIndexes[0].KeySchema[?KeyType=='HASH'].AttributeName|[0], GSI_SK:GlobalSecondaryIndexes[0].KeySchema[?KeyType=='RANGE'].AttributeName|[0], GSIProj:GlobalSecondaryIndexes[0].Projection.ProjectionType, SSEType:SSEDescription.SSEType, SSEKms:SSEDescription.KMSMasterKeyArn, Delete:DeletionProtectionEnabled}" --output json
aws dynamodb describe-continuous-backups --table-name unicorn-concert-db --query "ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus" --output text

echo "=== 5-1-A ==="
aws ecr describe-repositories --repository-names unicorn-concert-app --query "repositories[0].{Scan:imageScanningConfiguration.scanOnPush, Mutability:imageTagMutability, Enc:encryptionConfiguration.encryptionType}" --output json
aws ecr describe-images --repository-name unicorn-concert-app --query "sort(imageDetails[].imageTags[])" --output json | jq -r '@tsv'
aws ecr describe-image-scan-findings --repository-name unicorn-concert-app --image-id imageTag=v1.0.0 --query "imageScanFindingsSummary.findingSeverityCounts" --output json

echo "=== 6-1-A ==="
aws eks describe-cluster --name unicorn-eks-cluster --query "cluster.version" --output text
aws eks describe-cluster --name unicorn-eks-cluster --query "cluster.resourcesVpcConfig.[endpointPublicAccess, endpointPrivateAccess]" --output json | jq -r '@tsv'
aws eks describe-cluster --name unicorn-eks-cluster --query "cluster.logging.clusterLogging[?enabled==\`true\`].types[]" --output json | jq -r '@tsv'
aws eks describe-cluster --name unicorn-eks-cluster --query "cluster.encryptionConfig[].provider.keyArn" --output text
aws eks describe-cluster --name unicorn-eks-cluster --query "cluster.accessConfig.authenticationMode" --output text

echo "=== 6-2-A ==="
echo "[app node zones]"
kubectl get nodes -l unicorn=app -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' | sort | uniq -c
echo "[addon node count]"
kubectl get nodes -l unicorn=addon --no-headers | wc -l
echo "[ec2 name tag count: app / addon]"
aws ec2 describe-instances --filters Name=tag:Name,Values=unicorn-k8snode-app-node Name=instance-state-name,Values=running --query "length(Reservations[].Instances[])" --output text
aws ec2 describe-instances --filters Name=tag:Name,Values=unicorn-k8snode-addon-node Name=instance-state-name,Values=running --query "length(Reservations[].Instances[])" --output text
echo "[app nodes in private subnet?]"
aws ec2 describe-instances --filters Name=tag:Name,Values=unicorn-k8snode-app-node Name=instance-state-name,Values=running --query "Reservations[].Instances[].PublicIpAddress" --output json

echo "=== 6-3-A ==="
kubectl get deploy unicorn-book-app-deploy -n unicorn -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas' --no-headers
kubectl get svc unicorn-book-app-svc -n unicorn -o custom-columns='NAME:.metadata.name,TYPE:.spec.type' --no-headers
kubectl get deploy unicorn-book-app-deploy -n unicorn -o jsonpath='liveness={.spec.template.spec.containers[0].livenessProbe.httpGet.path} readiness={.spec.template.spec.containers[0].readinessProbe.httpGet.path}{"\n"}graceful={.spec.template.spec.terminationGracePeriodSeconds} preStop={.spec.template.spec.containers[0].lifecycle.preStop}{"\n"}'
kubectl get pods -n unicorn -l app -o jsonpath='{range .items[*]}{.spec.nodeSelector.unicorn}{"\n"}{end}' | sort -u
aws eks list-pod-identity-associations --cluster-name unicorn-eks-cluster --namespace unicorn --query "associations[].serviceAccount" --output text

echo "=== 7-1-A ==="
aws lambda get-function-configuration --function-name unicorn-get-booking-func --query "[FunctionName, KMSKeyArn, LoggingConfig.LogGroup]" --output json

echo "=== 8-1-A ==="
ALB_ARN=$(aws elbv2 describe-load-balancers --names unicorn-alb --query "LoadBalancers[0].LoadBalancerArn" --output text)
aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query "LoadBalancers[0].[Scheme, Type, State.Code]" --output text
aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query "Listeners[0].[Protocol, Port]" --output text
aws elbv2 describe-target-groups --names unicorn-tg --query "TargetGroups[0].[TargetType, Protocol, Port]" --output text

echo "=== 8-2-A ==="
aws cloudfront get-distribution-config --id $(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='unicorn-svc-cf'].Id | [0]" --output text) --query "DistributionConfig.Origins.Items[].[Id, OriginAccessControlId, VpcOriginConfig.VpcOriginId]" --output text
aws s3api get-bucket-policy --bucket unicorn-web-$(aws sts get-caller-identity --query Account --output text) --query "Policy" --output text | jq -r '.Statement[] | .Principal.Service, .Condition.StringEquals."AWS:SourceArn"'

echo "=== 8-3-A ==="
CF=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='unicorn-svc-cf'].DomainName | [0]" --output text)
RESP=$(curl -s -X POST "https://$CF/v1/book" -H 'Content-Type: application/json' -d '{"client_id":"C-MARK","username":"Judge","email":"judge@skills.kr","concert_name":"UnicornMark2026"}')
echo "$RESP"
BID=$(echo "$RESP" | jq -r '.booking_id')
aws dynamodb get-item --table-name unicorn-concert-db --key "{\"booking_id\":{\"S\":\"$BID\"}}" --query "Item.{booking_id:booking_id.S, client_id:client_id.S, concert_name:concert_name.S, created_at:created_at.S}" --output json

echo "=== 8-4-A ==="
curl -s "https://$CF/v1/book?booking_id=$BID" | jq .

echo "=== 8-5-A ==="
curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 -X POST "http://$(aws elbv2 describe-load-balancers --names unicorn-alb --query "LoadBalancers[0].DNSName" --output text)/v1/book" -H 'Content-Type: application/json' -d '{"client_id":"DIRECT"}' || echo "000"

echo "=== 8-6-A ==="
curl -s -o /dev/null -w "%{http_code}\n" "https://$CF/?probe=<script>alert(1)</script>"

echo "=== 9-1-A ==="
aws iam get-role --role-name unicorn-audit-role --query "Role.{MaxSession:MaxSessionDuration, Principal:AssumeRolePolicyDocument.Statement[0].Principal.AWS, ExternalId:AssumeRolePolicyDocument.Statement[0].Condition.StringEquals.\"sts:ExternalId\"}" --output json
for p in $(aws iam list-role-policies --role-name unicorn-audit-role --query "PolicyNames[]" --output text); do
  aws iam get-role-policy --role-name unicorn-audit-role --policy-name $p --query "PolicyDocument.Statement[].Action[]" --output text
done

echo "=== 9-2-A ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/unicorn-audit-role
echo "[1] no external-id:"; aws sts assume-role --role-arn $ROLE_ARN --role-session-name mk 2>&1 | grep -oE AccessDenied | head -1
read -r AK SK TK < <(aws sts assume-role --role-arn $ROLE_ARN --role-session-name mk --external-id unicorn-audit-2026$number --query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken]" --output text)
export AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$TK
echo "[2] assumed:"; aws sts get-caller-identity --query Arn --output text
echo "[3] allowed:"; aws ec2 describe-vpcs --filters Name=tag:Name,Values=unicorn-vpc --query "Vpcs[0].VpcId" --output text
echo "[4] denied:"; aws ec2 describe-instances 2>&1 | grep -oE "AccessDenied|UnauthorizedOperation" | head -1
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

echo "=== 10-1-A ==="
curl -s -o /dev/null -w "%{http_code}\n" "https://$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='unicorn-svc-cf'].DomainName | [0]" --output text)/health"
kubectl exec -n unicorn $(kubectl get pods -n unicorn -l app -o jsonpath='{.items[0].metadata.name}') -c book -- printenv AWS_REGION TABLE_NAME

echo "=== 11-1-A ==="
aws logs get-log-events --log-group-name /unicorn/eks/book-app --log-stream-name "$(aws logs describe-log-streams --log-group-name /unicorn/eks/book-app --order-by LastEventTime --descending --limit 1 --query "logStreams[0].logStreamName" --output text)" --limit 1 --start-from-head --query "events[-1].message" --output text | jq -r 'keys_unsorted | sort | join(",")'
aws logs filter-log-events --log-group-name /unicorn/eks/book-app --filter-pattern '"/health"' --query "events[].message" --output text | grep -c .

echo "=== 11-2-A ==="
kubectl get pods -n monitoring -o custom-columns='NAME:.metadata.name,STATUS:.status.phase' --no-headers | grep -iE "prometheus-|grafana"
kubectl get servicemonitor -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -iE "kube-controller-manager|kube-scheduler|kube-etcd" | wc -l

echo "=== 12-1-A ==="
date -u "+%Y-%m-%dT%H:%M:%SZ"
SINCE=$(date +%s)000
curl -s -X POST "https://$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='unicorn-svc-cf'].DomainName | [0]" --output text)/v1/book" -H 'Content-Type: application/json' -d '{"client_id":"C-FRESH","username":"Fresh","email":"fresh@skills.kr","concert_name":"FreshMark-7be3c9"}' > /dev/null
echo "waiting 30s for log pipeline" && sleep 30
aws logs filter-log-events --log-group-name /unicorn/eks/book-app --start-time $SINCE --filter-pattern '"FreshMark-7be3c9"' --query "events[].message" --output text | tail -1

echo "=== 12-2-A ==="
CF=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='unicorn-svc-cf'].DomainName | [0]" --output text)
sleep 60
for i in $(seq 1 100); do curl -s -o /dev/null "https://$CF/health"; done
sleep 30
curl -s -o /dev/null -w "%{http_code}\n" "https://$CF/health"
curl -s "https://$CF/health"

echo "=== 13-1-A ==="
echo 'manual marking'