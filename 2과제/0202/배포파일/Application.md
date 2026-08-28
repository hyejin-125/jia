# Application 설명서

## 개요
주문 로그를 생성하여 Kinesis Data Stream으로 전송하는 Python Flask 애플리케이션입니다.

## 실행 환경
- Python 3.12
- Flask + Gunicorn
- Port: 5000

## 배포 파일
배포파일은 EC2 인스턴스의 `/opt/app/` 경로에 위치합니다.

| 파일 | 설명 |
|------|------|
| app.py | 애플리케이션 소스 코드 |
| requirements.txt | Python 패키지 의존성 |

## 환경변수
애플리케이션은 아래 환경변수가 설정되어야 정상 실행됩니다.

| 변수명 | 설명 | 예시 |
|--------|------|------|
| STREAM_NAME | Kinesis Data Stream 이름 | wsc2026-order-stream |
| AWS_REGION | AWS 리전 | ap-northeast-2 |

## 실행 요구사항
- 애플리케이션은 **systemd 서비스**로 등록되어야 합니다.
- EC2 인스턴스 재시작 시 자동으로 실행되어야 합니다.
- gunicorn을 사용하여 실행합니다.

## API 엔드포인트

| Method | Path | 설명 |
|--------|------|------|
| GET | /health | 헬스체크 |
| POST | /order | 주문 1건 생성 → Kinesis 전송 |
| POST | /orders/generate | 주문 10건 일괄 생성 → Kinesis 전송 |

## Kinesis 레코드 형식

```json
{
  "order_id": "uuid",
  "product_name": "Laptop",
  "price": 1200000,
  "quantity": 2,
  "event_time": "2026-05-30 12:00:00"
}
```

## 헬스체크
ALB Target Group 헬스체크 경로: `/health`
