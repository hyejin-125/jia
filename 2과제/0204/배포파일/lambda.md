# Lambda

## Sensor Consumer Lambda

### 개요
MSK에서 원시 센서 데이터를 수신하여 이상 여부를 판단하고 분기 처리하는 Lambda 함수입니다.

- Runtime: Python 3.14
- Handler: index.handler

### 환경 변수

| Environment | Value |
|---|---|
| DDB_TABLE | wsc2026-sensor-data |
| ALERT_TOPIC | wsc2026-sensor-alert |
| BOOTSTRAP_SERVER | MSK broker endpoint |

### Lambda 이상 탐지 규칙

| Condition | Status |
|---|---|
| temperature > 80 | ALERT |
| temperature < 10 | ALERT |
| humidity > 90 | ALERT |
| humidity < 20 | ALERT |
| Otherwise | NORMAL |

### 이상 탐지 규칙
1. MSK 토픽에서 메시지 배치 수신
2. 각 메시지에 대해 온도/습도 임계치 확인
3. DynamoDB에 정상 데이터(NORMAL) 저장
4. wsc2026-sensor-alert Topic에 alert_reason 필드 추가 후 전송

### 출력 예시

```json
{
  "sensorId": "SENSOR-001",
  "timestamp": "2026-05-30T23:00:00+09:00",
  "temperature": 75.5,
  "humidity": 45.2,
  "location": "factory-a"
}
```

### 이상 데이터 출력 예시

```json
{
  "sensorId": "SENSOR-003",
  "timestamp": "2026-05-30T23:00:00+09:00",
  "temperature": 85.1,
  "humidity": 48.7,
  "location": "factory-a",
  "status": "ALERT",
  "alert_reason": "Temperature exceeded threshold: 85.1°C"
}
```

### 이상 데이터 사유

| Condition | Reason |
|---|---|
| temperature > 80 | Temperature exceeded threshold: {temperature}°C |
| temperature < 10 | Temperature below threshold: {temperature}°C |
| humidity > 90 | Humidity exceeded threshold: {humidity}% |
| humidity < 20 | Humidity below threshold: {humidity}% |

### 로그 출력 형식

```text
2026/05/30 14:00:00 Processing batch: 5 messages
2026/05/30 14:00:00 SENSOR-001: NORMAL - temp=75.5°C, humidity=45.2%
2026/05/30 14:00:00 SENSOR-002: NORMAL - temp=68.2°C, humidity=52.1%
2026/05/30 14:00:00 SENSOR-003: ALERT - temp=85.1°C (Temperature exceeded threshold)
```

## Alert Consumer Lambda

### 개요
이상 데이터를 수신하여 SNS 알림을 발송하고 S3에 로그를 저장하는 Lambda 함수입니다.

- Runtime: Python 3.14
- Handler: index.handler

### 환경 변수

| Environment | Value |
|---|---|
| SNS_TOPIC_ARN | alert SNS ARN |
| S3_BUCKET | S3 Bucket Name |

### 처리 로직
1. wsc2026-sensor-alert Topic에서 메시지 수신
2. SNS 알림 발송 (센서 ID, 이상 값, 발생 시간)
3. S3에 JSON 로그 저장

### S3 저장 경로

```text
/alert/{sensorId}/{date}/{timestamp}.json
```