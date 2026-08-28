# 1과제 실행 순서 — 위치별 / 대기시간

표기: **[쉘1]** CloudShell 첫번째 탭 · **[쉘2]** CloudShell 두번째 탭 · **[콘솔]** 브라우저 AWS 콘솔

> CloudShell 탭 추가: 우측 상단 **Actions ▸ New tab**
> 로컬 파일 업로드: **Actions ▸ Upload file** (홈 디렉터리 `~`로 들어감)

## 한눈에 보기

| # | 위치 | 작업 | 대기 |
|---|---|---|---|
| 1 | 쉘1 | 파일 업로드 + `01-vpc.sh` | **3~4분** |
| 2 | 쉘1 | `02-kms.sh` | 20초 |
| 3 | 쉘1 | `03-cluster.sh` (백그라운드) | **18~22분** |
| 4 | 쉘2 | `04-ecr.sh` | **4~6분** |
| 5 | 쉘2 | `05-dynamodb.sh` | 1~2분 |
| 6 | 콘솔 | S3 버킷 + 업로드 | 즉시 |
| 7 | 콘솔 | Lambda 생성 | 1분 |
| 8 | 쉘1 | `06-app.sh` | **8~12분** |
| 9 | 콘솔 | CloudFront 생성 | 입력 5분 + **배포 5~15분** |
| 10 | 쉘2 | `07-monitoring.sh` | **8~12분** |
| 11 | 콘솔 | KMS 키 정책 + S3 버킷 정책 | 2분 |
| 12 | 쉘1 | `mark.sh` 자가채점 | 1분 |

4~7번은 **3번 대기 중에** 병렬로 진행합니다. 9~10번도 겹칩니다.

---

## 1. [쉘1] 사전 준비 + VPC

**Actions ▸ Upload file** 로 `book`, `index.html`, `main.jpeg`, `lambda.py` 를 올립니다.

```bash
export AWS_PAGER=""
export AWS_DEFAULT_REGION=ap-northeast-2
export BNUM=<비번호>
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET=wskorea26-concert-bucket-$BNUM

wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/01-vpc.sh
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/02-kms.sh
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/03-cluster.sh

bash 01-vpc.sh
```

⏱ **3~4분** — `aws ec2 wait nat-gateway-available` 에서 멈춰 있는 게 정상. NAT 게이트웨이 2개가 뜰 때까지입니다.

완료 확인:
```bash
aws ec2 describe-nat-gateways --filter Name=state,Values=available \
  --query 'length(NatGateways)' --output text   # 2
```

## 2. [쉘1] KMS

```bash
bash 02-kms.sh
```
⏱ **20초**. 키 4개(s3/ecr/dynamodb/eks) 생성.

```bash
aws kms list-aliases --query "Aliases[?starts_with(AliasName,'alias/wskorea26')].AliasName" --output text
```

## 3. [쉘1] EKS 클러스터 — 최대 병목

브라우저 탭이 닫히거나 세션이 끊겨도 살아남도록 백그라운드로 돌립니다.

```bash
nohup bash 03-cluster.sh > cluster.log 2>&1 &
tail -f cluster.log
```

⏱ **18~22분** (컨트롤 플레인 ~10분 → 노드그룹 2개 ~6분 → OIDC/IAM SA ~3분)

`tail`은 Ctrl+C로 빠져나와도 작업은 계속됩니다. 진행 상황:
```bash
aws eks describe-cluster --name wskorea26-cluster --query cluster.status --output text
aws cloudformation describe-stacks \
  --query "Stacks[?contains(StackName,'wskorea26')].[StackName,StackStatus]" --output table
```

**⚠ 여기서부터 아래 4~7번을 다른 탭/브라우저에서 동시에 진행하세요.**

---

## 4. [쉘2] ECR

```bash
export AWS_PAGER=""
export AWS_DEFAULT_REGION=ap-northeast-2
docker info > /dev/null 2>&1 && echo "docker OK" || echo "docker 불가"
```

`docker 불가`면 이 단계만 EC2/다른 빌드 환경에서 진행해야 합니다.

```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/04-ecr.sh
bash 04-ecr.sh
```

⏱ **4~6분** (apt update/upgrade 포함 이미지 빌드 3분 + 푸시 1분)

⚠ 스크립트가 `REGION` 정의 전에 `export AWS_DEFAULT_REGION="$REGION"` 을 하므로 위에서 미리 export 해두는 게 필수입니다. `book` 파일이 실행 디렉터리에 있어야 합니다.

취약점 스캔 결과는 푸시 후 **1~2분 더** 지나야 조회됩니다:
```bash
aws ecr describe-image-scan-findings --repository-name wskorea26-book-repo \
  --image-id imageTag=stable --query imageScanFindings.findingSeverityCounts
```

## 5. [쉘2] DynamoDB + Lambda 역할

```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/05-dynamodb.sh
bash 05-dynamodb.sh
```
⏱ **1~2분** (테이블 ACTIVE 30초 + IAM 역할/정책)

```bash
aws dynamodb describe-table --table-name wskorea26-data-table \
  --query Table.TableStatus --output text   # ACTIVE
```

## 6. [콘솔] S3

**S3 ▸ 버킷 만들기**
- 이름 `wskorea26-concert-bucket-<비번호>` / 리전 서울
- 퍼블릭 액세스 차단 **4개 모두 체크 유지**
- 기본 암호화: **SSE-KMS**, `alias/wskorea26-s3-key` 선택, 버킷 키 활성화

**폴더 만들기** `web` ▸ 그 안에 `main` ▸ `index.html`, `main.jpeg` 업로드
업로드 시 **속성 ▸ 서버 측 암호화 ▸ KMS ▸ wskorea26-s3-key** 를 명시적으로 지정.

⏱ 즉시. 확인:
```bash
aws s3api head-object --bucket $BUCKET --key web/main/index.html \
  --query '[ServerSideEncryption,SSEKMSKeyId]' --output text
```
`aws:kms` 가 아니면 다시 올리세요. 셸에서 하는 편이 확실합니다:
```bash
S3_KEY=$(aws kms describe-key --key-id alias/wskorea26-s3-key --query KeyMetadata.Arn --output text)
aws s3 cp index.html s3://$BUCKET/web/main/index.html --sse aws:kms --sse-kms-key-id "$S3_KEY"
aws s3 cp main.jpeg  s3://$BUCKET/web/main/main.jpeg  --sse aws:kms --sse-kms-key-id "$S3_KEY"
```

## 7. [콘솔] Lambda

**Lambda ▸ 함수 생성 ▸ 새로 작성**
- 이름 `wskorea26-book-lambda`
- 런타임 **Python 3.14**
- 실행 역할: **기존 역할 사용 ▸ `wskorea26-book-lambda-role`** (5번에서 생성됨)

생성 후:
- **코드** 탭에 `lambda.py` 내용 붙여넣기 ▸ **Deploy** (⏱ 10초)
- **구성 ▸ 일반 구성 ▸ 편집** ▸ 제한 시간 `30`초
- **구성 ▸ 환경 변수** ▸ `TABLE_NAME` = `wskorea26-data-table`

⏱ 전체 1~2분.

> 코드의 `dynamodb.Table('wskorea26-data-table')` 을 `os.environ['TABLE_NAME']` 으로 바꿔두면 환경변수가 실제로 동작합니다.

테스트 이벤트 `{"queryStringParameters":{"concert_name":"TEST"}}` 로 200이 나오는지 확인 (⏱ 첫 실행 콜드스타트 3초).

---

## 8. [쉘1] 앱 배포 — 3번이 끝난 뒤

```bash
tail cluster.log        # "EKS cluster ... is ready" 확인
kubectl get nodes       # 4대 Ready
```

```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/06-app.sh
rm -f service.yaml ingress.yaml deployment.yaml
bash 06-app.sh
```

⏱ **8~12분** 내역:
- LB Controller Helm 설치 → Pod Ready **1~2분**
- `eksctl create iamserviceaccount` (CloudFormation) **2~3분**
- Ingress → ALB 프로비저닝 **3~5분**
- 타겟 healthy **1~2분**

⚠ Lambda(7번)가 없으면 `LAMBDA_ARN` 조회에서 실패합니다.

진행 확인:
```bash
kubectl get pod -n wskorea26
kubectl get ingress -n wskorea26 -w      # ADDRESS 채워지면 완료
ALB_DNS=$(aws elbv2 describe-load-balancers --names wskorea26-book-alb \
  --query 'LoadBalancers[0].DNSName' --output text)
curl -o /dev/null -s -w "%{http_code}\n" http://$ALB_DNS/book    # 403 이면 정상
```
DNS 이름이 해석되기까지 추가로 **1~3분** 걸릴 수 있습니다(처음엔 curl이 실패해도 정상).

## 9. [콘솔] CloudFront

**CloudFront ▸ 배포 생성**

| 항목 | 값 |
|---|---|
| 설명(Comment) | `wskorea26-concert-cf` |
| 원본 1 이름 | `wskorea26-s3-origin` |
| 원본 도메인 | S3 버킷 선택 |
| 원본 경로 | `/web/main` |
| 원본 액세스 | **OAC** ▸ 새로 생성 ▸ 서명 always |
| 사용자 정의 헤더 | `wskorea26-s3-access` : `true` |
| 원본 2 이름 | `wskorea26-alb-origin` |
| 원본 도메인 | ALB DNS 이름 |
| 프로토콜 | **HTTP only**, 포트 80 |
| 사용자 정의 헤더 | `X-Origin-Verify` : `wskorea26-cf` |
| 기본 동작 | 대상 `wskorea26-s3-origin`, 뷰어 정책 **HTTP를 HTTPS로 리디렉션**, 캐시 정책 CachingOptimized |
| 추가 동작 | 경로 `/book*`, 대상 `wskorea26-alb-origin`, 메서드 **GET,HEAD,OPTIONS,PUT,POST,PATCH,DELETE**, 캐시 정책 **CachingDisabled**, 원본 요청 정책 **AllViewerExceptHostHeader** |
| 기본값 루트 객체 | `index.html` |

⏱ 입력 5분 + **배포 5~15분** (상태가 `배포 중` → `배포됨`)

```bash
CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='wskorea26-concert-cf'].Id | [0]" --output text)
aws cloudfront wait distribution-deployed --id $CF_ID
```

> ALB 원본은 **AllViewer 말고 AllViewerExceptHostHeader**. Host 헤더까지 넘기면 ALB 라우팅이 깨집니다. 쿼리 문자열은 이 정책이 전부 전달합니다.

배포 생성 직후 콘솔이 안내하는 **S3 버킷 정책 복사(Copy policy)** 버튼을 눌러 S3 ▸ 권한 ▸ 버킷 정책에 붙여넣습니다. (⏱ 즉시)

## 10. [쉘2] 모니터링 — CF 배포 대기 중에 진행

```bash
export BNUM=<비번호>
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/07-monitoring.sh
bash 07-monitoring.sh
```

⏱ **8~12분** 내역:
- kube-prometheus-stack Helm **4~6분**
- fluent-bit **1분**
- Grafana ALB 프로비저닝 **3~5분**

```bash
kubectl get pod -n monitoring
kubectl get ingress -n monitoring
```
접속: `http://<ALB주소>/d/wskorea26/wskorea26-monitoring`
로그인 `skills-<비번호>-admin` / `$korea26!!`

> `mark.sh` 10-1은 `monitoring` 네임스페이스의 **`grafana`라는 이름의 Service**에서 주소를 읽습니다. 출력까지 맞추려면:
> ```bash
> kubectl -n monitoring expose deployment monitoring-grafana \
>   --name=grafana --type=LoadBalancer --port=80 --target-port=3000
> ```
> ⏱ NLB/CLB 생성 **3~4분**

## 11. [콘솔] KMS 키 정책 ★ 잊으면 정적 페이지 403

**KMS ▸ 고객 관리형 키 ▸ `wskorea26-s3-key` ▸ 키 정책 ▸ 편집**
기존 내용을 지우지 말고 `Statement` 배열에 **추가**:

```json
{
    "Sid": "AllowCloudFrontDecrypt",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": ["kms:Decrypt", "kms:DescribeKey"],
    "Resource": "*",
    "Condition": {
        "StringEquals": { "aws:SourceArn": "<CLOUDFRONT_ARN>" }
    }
}
```

```bash
aws cloudfront get-distribution --id $CF_ID --query Distribution.ARN --output text
```

⏱ 저장 즉시 반영. 단 CloudFront가 이미 403을 캐싱했다면 무효화 필요:
```bash
aws cloudfront create-invalidation --distribution-id $CF_ID --paths "/*"
```
⏱ 무효화 **1~2분**

## 12. [쉘1] 최종 검증

```bash
CF_DOMAIN=$(aws cloudfront get-distribution --id $CF_ID --query Distribution.DomainName --output text)
curl -o /dev/null -s -w "%{http_code}\n" https://$CF_DOMAIN            # 200
curl -o /dev/null -s -w "%{http_code}\n" http://$CF_DOMAIN/            # 301
curl -o /dev/null -s -w "%{http_code}\n" https://$CF_DOMAIN/main.jpeg  # 200
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"client_id":"D1114","username":"akane","email":"a@b.com","concert_name":"TEST"}' \
  https://$CF_DOMAIN/book
curl -s "https://$CF_DOMAIN/book?concert_name=TEST"                    # JSON
curl -s -o /dev/null -w "%{http_code}\n" https://$CF_DOMAIN/book       # 400
```

```bash
bash mark.sh 2>&1 | tee result.txt
```
⏱ **1~2분** (curl 왕복 포함)

---

## 누적 소요 예상

| 구간 | 누적 |
|---|---|
| 1~2 (VPC/KMS) | T+5분 |
| 3 클러스터 (4~7 병행) | T+27분 |
| 8 앱 배포 | T+38분 |
| 9 CF 생성 (10 병행) | T+58분 |
| 11~12 마무리 | T+70분 |

4시간 중 **약 70~90분**이면 1회차가 끝납니다. 나머지는 재시도와 검증에 쓰세요. 실패 시 가장 비싼 롤백은 3번(클러스터 22분)이므로, `03-cluster.sh` 실행 직전에 KMS 별칭과 서브넷 태그를 반드시 확인하세요.
