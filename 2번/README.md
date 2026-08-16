## shell
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/01-vpc.sh
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/02-kms.sh
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/03-cluster.sh
```

<br>

## S3
- wskorea26-concert-bucket-<비번호>
- /web/main/
- KMS
```bash
aws s3 rm s3://$BUCKET/web/main/
```

<br>

## shell
- 배포파일/book
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/04-ecr.sh
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/05-dynamodb.sh
```

<br>

## Lambda
- wskorea26-book-lambda
- Python 3.14
- 30초
- 환경변수 { TABLE_NAME: wskorea26-data-table }

<br>

## app
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/06-app.sh
```

<br>

## monitoring
```bash
export BNUM=<비번호>
```
```bash
wget https://raw.githubusercontent.com/zjarhkrh/skills/refs/heads/main/1과제/2번/07-monitoring.sh
```

<br>

## CF
- wskorea26-concert-cf
- name: wskorea26-s3-origin ( * )
- /web/main
- default root: /index.html
- S3 OAC 원본 엑세스
- S3 원본 > 사용자 정의 헤더 ( wskorea26-s3-access: true )
- S3 KMS 연결

- name: wskorea26-alb-origin ( /book* )
- ALB 원본 > 사용자 정의 헤더 ( X-Origin-Verify: wskorea26-cf )
- ALB 동작 > 쿼리 문자열 모두
```bash
{
    "Sid": "Decrypy Role",
    "Effect": "Allow",
    "Principal": {
        "Service": "cloudfront.amazonaws.com"
    },
    "Action": "kms:*",
    "Resource": "*",
    "Condition": {
        "StringEquals": {
            "aws:SourceArn": "<CLOUDFRONT_ARN>"
        }
    }
}
```
