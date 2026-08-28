# 1과제 (Unicorn Tickets / Solution Architecture) 실행 순서 — 위치별 / 대기시간

표기: **[로컬]** 내 PC 터미널(PowerShell) · **[콘솔]** 브라우저 AWS 콘솔 · **[VPC셸]** CloudShell VPC 환경 `unicorn-mark`

> 이번 과제는 앞의 두 과제와 달리 **Terraform으로 로컬에서 전부 만들고**, CloudShell은 마지막 설정 변경과 채점에만 씁니다.
> 채점기준 14) — 모든 채점은 서울 리전 **CloudShell VPC Environment `unicorn-mark`** 에서 진행.
> 채점기준 13) — `mark.sh` 는 `/home/cloudshell-user` 에 두어야 합니다.

## 한눈에 보기

| # | 위치 | 작업 | 대기 |
|---|---|---|---|
| 0 | 콘솔/로컬 | IAM 사용자 + `aws configure` + choco 설치 | 5분 |
| 1 | 로컬 | `contestant_number` 수정 (2곳) | 1분 |
| 2 | 로컬 | `01-vpc` **apply** | **30~40분** |
| 3 | 로컬 | `docker pull` 5종 (2번과 병행) | **10~15분** |
| 4 | 로컬 | S3 업로드 | 1분 |
| 5 | 로컬 | ECR 빌드 + 푸시 | **10~15분** |
| 6 | 로컬 | `02-k8s` **apply** (2단계) | **12~18분** |
| 7 | 콘솔 | CloudShell VPC 환경 `unicorn-mark` 생성 | **3~5분** |
| 8 | VPC셸 | `authenticationMode=API` | **3~5분** |
| 9 | VPC셸 | `endpointPublicAccess=false` | **5~10분** |
| 10 | VPC셸 | ALB / 클러스터 보안그룹 정리 | 1분 |
| 11 | VPC셸 | ALB 트래픽 50회 생성 | 1분 |
| 12 | VPC셸 | `mark.sh` 자가 채점 | **5분** |

3번은 2번 돌아가는 동안 다른 창에서 같이 진행합니다.

> ⚠ **순서를 바꾸면 안 되는 3곳**
> ① ECR 푸시는 `01-vpc` 이후 (리포지토리를 Terraform이 만듭니다)
> ② `02-k8s` 는 엔드포인트가 **아직 퍼블릭일 때** (기본 `eks_bootstrap_public_access = true`)
> ③ 엔드포인트를 프라이빗으로 닫는 건 **CloudShell을 만든 뒤**

---

## 0. [콘솔/로컬] 사전 준비

콘솔에서 **IAM ▸ 사용자 생성** → `AdministratorAccess` 부여 → 액세스 키 발급.
이 사용자로 **콘솔에도 로그인**해 두세요. 나중에 CloudShell이 같은 주체로 동작해야 EKS 접근 권한(액세스 엔트리)이 그대로 유지됩니다.

```powershell
aws configure    # 키/시크릿/ap-northeast-2/json

Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
choco install kubernetes-cli kubernetes-helm terraform -y
```

⏱ **5분**. Docker Desktop이 떠 있는지도 확인하세요 (5번에서 필요).

```powershell
terraform version; kubectl version --client; docker info
```

## 1. [로컬] 변수 수정 — **두 파일 모두**

`01-vpc/variables.tf` 와 `02-k8s/variables.tf` 의 `contestant_number` 기본값을 비번호로 바꿉니다.

```hcl
variable "contestant_number" {
  default = "<비번호>"
}
```

이 값이 감사 역할의 `ExternalId`(`unicorn-audit-2026<비번호>`)와 Grafana 계정(`skills<비번호>` / `HelloKrSkills!<비번호>@`)에 그대로 들어갑니다. 한쪽만 고치면 9-2-A가 틀립니다.

**같이 손봐두면 좋은 것 2가지**

| 파일 | 문제 | 조치 |
|---|---|---|
| `01-vpc/providers.tf` | kubernetes/helm provider의 `args` 끝에 값 없는 `"--profile"` | 그 줄 삭제 (01-vpc엔 k8s 리소스가 없어 지금은 무해하지만 지뢰) |
| `02-k8s/helm.tf` | `clusterName = "unicorn-cluster"` | **`unicorn-eks-cluster`** 로 수정 |

## 2. [로컬] 01-vpc — 최대 병목

```powershell
cd .\01-vpc
terraform init
terraform plan
terraform apply -auto-approve
```

⏱ **30~40분** 내역:

- VPC / 서브넷 6개 / **NAT 3개** ~3분
- 인터페이스 VPC 엔드포인트 7종 + S3 게이트웨이 ~3분
- **EKS 클러스터 ~10분** → 노드그룹 2개(addon 2대, app 3대) ~5분 → CoreDNS 애드온
- **CloudFront VPC Origin ~10~15분** (가장 느립니다) → 배포 ~6~10분
- WAF(us-east-1) / Lambda / DynamoDB / S3 / ECR 4개 / audit 역할

한 번에 만들어지는 것: VPC · KMS 3키(90일 자동 교체) · S3(버저닝+KMS) · ECR · DynamoDB(`booking_id` PK, `client-id-created-at-index` GSI, PITR) · EKS · ALB 2대 · Lambda · WAF · CloudFront · Flow Logs · `unicorn-cloudshell-sg`.

진행 확인은 다른 창에서:
```powershell
aws eks describe-cluster --name unicorn-eks-cluster --query cluster.status --output text
```

**⚠ 이 40분 동안 3번을 같이 돌리세요.**

## 3. [로컬] Docker 이미지 미리 받기 — 2번과 병행

ECR 리포지토리는 아직 없어도 **pull은 지금 가능**합니다. 용량이 커서 미리 받아두면 5번이 훨씬 짧아집니다.

```powershell
docker pull grafana/grafana:11.4.0
docker pull curlimages/curl:8.9.1
docker pull public.ecr.aws/eks/aws-load-balancer-controller:v2.13.4
docker pull quay.io/kiwigrid/k8s-sidecar:1.28.0
```

⏱ **10~15분** (grafana 이미지가 ~450MB로 대부분을 차지)

## 4. [로컬] S3 업로드 — 2번 완료 후

```powershell
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
aws s3 cp .\index.html s3://unicorn-web-$ACCOUNT_ID/index.html
aws s3 cp .\main.jpeg  s3://unicorn-web-$ACCOUNT_ID/main.jpeg
```

⏱ 즉시. 버킷 기본 암호화가 이미 `unicorn-kms-data`로 걸려 있어 자동으로 KMS 암호화됩니다.

## 5. [로컬] ECR 빌드 + 푸시

`kiwigrid/k8s-sidecar` 리포지토리만 Terraform에 없으므로 직접 만듭니다.

```powershell
$env:ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
$env:REGION = "ap-northeast-2"
aws ecr get-login-password --region $env:REGION | docker login --username AWS --password-stdin "$($env:ACCOUNT_ID).dkr.ecr.$($env:REGION).amazonaws.com"
aws ecr create-repository --repository-name kiwigrid/k8s-sidecar --region $env:REGION
```

`book` 바이너리가 있는 폴더에서 Dockerfile 생성 후 빌드:

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache ca-certificates coreutils
COPY book /book
EXPOSE 8080
ENTRYPOINT ["/book"]
```

```powershell
docker build -t unicorn-concert-app:v1.0.0 .
docker tag unicorn-concert-app:v1.0.0 "$($env:ACCOUNT_ID).dkr.ecr.$($env:REGION).amazonaws.com/unicorn-concert-app:v1.0.0"
docker push "$($env:ACCOUNT_ID).dkr.ecr.$($env:REGION).amazonaws.com/unicorn-concert-app:v1.0.0"
```

나머지 4개도 태그 후 푸시 (README의 명령 그대로):
`grafana:11.4.0` · `curlimages/curl:8.9.1` · `ecr-public/eks/aws-load-balancer-controller:v2.13.4` · `kiwigrid/k8s-sidecar:1.28.0`

⏱ **10~15분** (3번에서 미리 pull 했다면 5~8분)

⚠ `unicorn-concert-app` 은 **IMMUTABLE_WITH_EXCLUSION**(예외: `latest`)이라 `v1.0.0` 재푸시가 안 됩니다. 이미지를 고쳐야 하면 먼저 삭제하세요.

```powershell
aws ecr describe-images --repository-name unicorn-concert-app --query "imageDetails[].imageTags" --output text
```
스캔 결과는 푸시 후 **1~2분** 뒤에 조회됩니다(채점 5-1-A).

## 6. [로컬] 02-k8s — 반드시 2단계로

```powershell
aws eks update-kubeconfig --region ap-northeast-2 --name unicorn-eks-cluster
cd ..\02-k8s
terraform init
terraform apply -target="helm_release.aws_load_balancer_controller" -auto-approve
terraform apply -auto-approve
```

⏱ **12~18분** 내역:
- LB Controller Helm + Pod Ready **2~3분**
- 네임스페이스/SA/Deployment/Service **1분**
- **kube-prometheus-stack Helm 5~8분** (차트 timeout 900초)
- fluent-bit DaemonSet, TargetGroupBinding 2개 **1분**
- 타겟 등록 + healthy **2~3분**

> **왜 `-target` 을 먼저 돌리나** — `TargetGroupBinding` 은 `kubernetes_manifest` 리소스인데, 이건 **plan 시점에 CRD가 클러스터에 이미 있어야** 합니다. LB Controller가 그 CRD를 설치하므로 반드시 먼저 올려야 하고, 그러지 않으면 첫 apply가 CRD 없음으로 실패합니다.

```powershell
kubectl get pods -n unicorn
kubectl get pods -n monitoring
kubectl get pods -n logging
aws elbv2 describe-target-health --target-group-arn (aws elbv2 describe-target-groups --names unicorn-tg --query "TargetGroups[0].TargetGroupArn" --output text)
```

CloudFront 도메인으로 동작 확인:
```powershell
terraform -chdir=..\01-vpc output cloudfront_domain_name
```

## 7. [콘솔] CloudShell VPC 환경 생성

CloudShell **Actions ▸ Create VPC environment**

| 항목 | 값 |
|---|---|
| 이름 | **`unicorn-mark`** |
| VPC | `unicorn-vpc` |
| 서브넷 | **`unicorn-subnet-priv-a`** |
| 보안 그룹 | **`unicorn-cloudshell-sg`** |

⏱ **3~5분**. 프롬프트가 뜨면:

```bash
aws sts get-caller-identity        # 2번에서 쓴 IAM 사용자와 동일해야 함
aws eks update-kubeconfig --region ap-northeast-2 --name unicorn-eks-cluster
kubectl get nodes
```

`mark.sh` 를 `/home/cloudshell-user` 에 올려둡니다 (채점기준 13).

> 여기서 `kubectl get nodes` 가 안 되면 8~9번을 진행하지 마세요. 엔드포인트를 닫는 순간 복구가 어려워집니다.

## 8. [VPC셸] 인증 모드 변경

```bash
aws eks update-cluster-config \
  --name unicorn-eks-cluster \
  --access-config authenticationMode=API
```

⏱ **3~5분**. 클러스터가 `UPDATING` 인 동안에는 **두 번째 업데이트를 받지 않습니다.** 반드시 `ACTIVE` 로 돌아온 것을 확인하고 9번으로 넘어가세요.

```bash
aws eks describe-cluster --name unicorn-eks-cluster --query cluster.status --output text
```

## 9. [VPC셸] 엔드포인트 프라이빗 전환

```bash
aws eks update-cluster-config \
  --name unicorn-eks-cluster \
  --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true
```

⏱ **5~10분**. 이 시점부터 **로컬 PC에서는 kubectl/terraform으로 클러스터를 못 만집니다.** k8s 쪽에 고칠 게 남았다면 되돌아가지 말고 이 셸에서 처리하세요.

```bash
aws eks describe-cluster --name unicorn-eks-cluster \
  --query "cluster.resourcesVpcConfig.[endpointPublicAccess,endpointPrivateAccess]" --output text   # False True
kubectl get nodes    # 여전히 동작해야 정상
```

## 10. [VPC셸] ALB / 클러스터 보안그룹 정리

Terraform이 부트스트랩용으로 열어둔 규칙을 좁히는 단계입니다. ALB는 **CloudFront VPC Origin 전용 SG에서만** 받도록 바꿉니다.

```bash
export AWS_PAGER=""
ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=unicorn-alb-sg" \
  --query "SecurityGroups[0].GroupId" --output text)
aws ec2 describe-security-groups --group-ids $ALB_SG \
  --query "SecurityGroups[0].IpPermissions" --output json > /tmp/all_ingress_rules.json
aws ec2 revoke-security-group-ingress \
  --group-id $ALB_SG --ip-permissions file:///tmp/all_ingress_rules.json 2>/dev/null

VPCO_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=CloudFront-VPCOrigins-Service-SG" \
  --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$VPCO_SG,Description='Allow CloudFront VPC Origin All Traffic'}]"

EKS_SG=$(aws eks describe-cluster --name unicorn-eks-cluster \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $EKS_SG --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 revoke-security-group-ingress  --group-id $EKS_SG --protocol all --cidr 0.0.0.0/0
```

⏱ 즉시. **443 허용을 먼저 넣고 전체 허용을 회수하는 순서**입니다. 뒤집으면 이 셸이 클러스터와 끊깁니다.

`CloudFront-VPCOrigins-Service-SG` 는 VPC Origin이 만들어질 때 AWS가 자동 생성하므로, 2번이 끝난 뒤에만 조회됩니다.

검증 — CloudFront 경유는 되고 ALB 직접은 막혀야 합니다.
```bash
CF=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='unicorn-svc-cf'].DomainName | [0]" --output text)
curl -s -o /dev/null -w "%{http_code}\n" "https://$CF/health"     # 200
curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 \
  "http://$(aws elbv2 describe-load-balancers --names unicorn-alb --query 'LoadBalancers[0].DNSName' --output text)/health"   # 000
```

## 11. [VPC셸] ALB 트래픽 생성

로그 파이프라인과 대시보드에 데이터를 채웁니다(11-1-A, 12-1-A, 13-1-A 수동 채점).

```bash
CF_DOMAIN=$(aws cloudfront list-distributions --query "DistributionList.Items[0].DomainName" --output text)
for i in {1..50}; do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "https://$CF_DOMAIN/v1/book" \
    -H 'Content-Type: application/json' \
    -d '{"client_id":"NORMAL_USER"}'
  sleep 0.5
done
```

⏱ **1분** + 로그가 CloudWatch에 도착하기까지 **30초~1분**.

```bash
aws logs describe-log-streams --log-group-name /unicorn/eks/book-app \
  --order-by LastEventTime --descending --limit 1 --query "logStreams[0].logStreamName" --output text
```

> WAF에 **분당 50 요청 레이트 리밋**이 걸려 있습니다. 위 루프를 0.5초 간격으로 도는 이유이고, 채점 12-2-A는 반대로 100회를 몰아쳐서 **403이 나오는지**를 봅니다. 검증한다고 빠르게 여러 번 때리면 한동안 403이 이어지니, 그럴 땐 **2~3분 쉬었다가** 다시 확인하세요.

## 12. [VPC셸] 자가 채점

`mark.sh` 9-2-A가 `unicorn-audit-2026$number` 로 ExternalId를 조립합니다. 셸 변수가 비어 있으면 무조건 실패하니 먼저 넣어주세요.

```bash
export number=<비번호>
cd /home/cloudshell-user
bash mark.sh 2>&1 | tee result.txt
```

⏱ **5분** — 12-1-A에 `sleep 30`, 12-2-A에 `sleep 60` + 100회 요청 + `sleep 30` 이 들어 있습니다.

먼저 확인할 항목: `6-1-A`(False/True/API) · `8-2-A`(OAC + VpcOriginId) · `8-5-A`(000) · `9-2-A`(AccessDenied → 성공 → 거부) · `11-1-A`(`/health` 카운트 **0**).

## 13. [콘솔] 수동 채점 대비 — Grafana

`unicorn-grafana-alb` 는 인터넷 페이싱이라 브라우저에서 바로 열립니다.

```bash
terraform -chdir=01-vpc output grafana_alb_dns_name    # 또는
aws elbv2 describe-load-balancers --names unicorn-grafana-alb --query "LoadBalancers[0].DNSName" --output text
```

로그인 `skills<비번호>` / `HelloKrSkills!<비번호>@`
대시보드는 ConfigMap `unicorn-grafana-dashboard` 가 사이드카로 자동 로드됩니다. 11번 트래픽을 넣은 뒤 패널에 값이 그려지는지 눈으로 확인하세요.

---

## 누적 소요 예상

| 구간 | 누적 |
|---|---|
| 0~1 준비 | T+8분 |
| 2 `01-vpc` (3번 병행) | T+48분 |
| 4~5 S3 + ECR | T+60분 |
| 6 `02-k8s` | T+76분 |
| 7~9 CloudShell + 엔드포인트 전환 | T+95분 |
| 10~13 마무리 | T+105분 |

4시간 중 **약 105~125분**에 1회차가 끝납니다.

## 가장 비싼 실수 3가지

1. **`02-k8s` 전에 엔드포인트를 닫는 것** — 로컬 Terraform이 클러스터에 접근하지 못해 k8s 리소스를 아예 만들 수 없습니다. 순서는 `02-k8s` → CloudShell → 엔드포인트 차단.
2. **`-target` 없이 `02-k8s` 를 한 번에 apply** — `TargetGroupBinding` CRD가 없어 plan 단계에서 실패합니다.
3. **`contestant_number` 를 한쪽만 수정** — 9-2-A(ExternalId)와 Grafana 로그인이 어긋납니다.

되돌리기 비용이 가장 큰 건 `01-vpc` 의 CloudFront VPC Origin(재생성 시 15분 이상)이니, `terraform destroy` 는 정말 마지막 수단으로만 쓰세요.
