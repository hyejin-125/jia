## CloudShell
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/3번/01-vpc.sh
```
- mark-sg
- wsc2026-skills-app-sub-a에 연결

<br>

## shell
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/3번/02-kms.sh
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/3번/03-cluster.sh
```

<br>

## S3
- wsc2026-static-<임의의 영문 4자리>-<비번호>-bucket
- KMS
- /static

<br>

## ECR
- 배포파일/book
- v1* 설정
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/3번/04-ecr.sh
```

<br>

## DynamoDB
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/3번/05-dynamodb.sh
```

<br>

## Lambda
- wsc2026-book-get-function
- Python 3.12
- kms 연결 ( 시작, 환경변수 )
- 30초
- 환경변수 { TABLE_NAME: wsc2026-book-table(암호화) }

<br>

## shell
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/3번/06-app.sh
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/3번/07-monitoring.sh
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/3번/08-waf.sh
```

<br>

## CloudFront
- wsc2026-cdn
- WAF 연결
- origin: /static
- origin: index.html
- Viewer Requests ( ALB )
- ALB: /booking
- ALB 뭐시기: Cac...Disabled
- ALB Header: AllViewerExceptHostHeader
- lambda functioon url
- Lambda: /v1/book
```json
{
  "Sid": "Decrypt Role",
  "Effect": "Allow",
  "Principal": {
    "Service": "cloudfront.amazonaws.com"
  },
  "Action": [
    "kms:Decrypt",
    "kms:GenerateDataKey*"
  ],
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "aws:SourceArn": "<CloudFront ARN>"
    }
  }
}
```
```bash
function handler(event) {
  var request = event.request;
  if (request.uri === '/booking') { request.uri = '/v1/book'; } 
  else if (request.uri === '/booking/') { request.uri = '/v1/book'; }
  return request;
}
```
