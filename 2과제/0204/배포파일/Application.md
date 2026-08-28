# Application

## 개요
배포된 app 파일은 Go 바이너리 실행 파일입니다. 데이터를 MSK Topic으로 발행합니다.

## 필수 애플리케이션 변수

| Enviroment | Value |
|---|---|
| BOOTSTRAP_SERVERS | MSK broker endpoint |
| TOPIC_RAW | MSK raw data topic name |

## 애플리케이션 실행
애플리케이션은 실행 시 백그라운드에서 지속 실행됩니다. EC2 재시작 시에도 애플리케이션이 실행되도록 구성합니다.

## 애플리케이션 출력
애플리케이션은 출력으로 JSON 형식의 공장 온/습도 데이터를 출력합니다.

| Field | Type | Description |
|---|---|---|
| sensorId | String | Sensor unique id |
| timestamp | String | ISO 8601 (KST,UTC + 09:00) |
| temperature | Float | Temperature (°C) |
| humidity | Float | Humidity (%) |
| location | String | Senesor Location |

## 애플리케이션 출력 예시

```json
{
  "sensorId": "SENSOR-001",
  "timestamp": "2026-05-30T23:00:00+09:00",
  "temperature": 75.5,
  "humidity": 45.2,
  "location": "factory-a"
}
```

## 애플리케이션 로그 출력 형식

```text
2026/05/30 14:00:00 Starting sensor producer
2026/05/30 14:00:05 SENSOR-001: temp=75.5°C, humidity=45.2%
2026/05/30 14:00:05 SENSOR-002: temp=68.2°C, humidity=52.1%
2026/05/30 14:00:05 SENSOR-003: temp=82.1°C, humidity=48.7%
```
