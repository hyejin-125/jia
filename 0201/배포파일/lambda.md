# Lambda Function 명세서

---

## 함수 목록

본 과제에서는 아래 2개의 Lambda 함수를 구성해야 합니다.

| 구분 | 함수명 | 역할 | 비고 |
|------|--------|------|------|
| A | 성적 처리 함수 | CSV 검증 → 평균/등급 계산 → DynamoDB 저장 | 코드 일부 제공 (TODO 완성 필요) |
| B | 트리거 함수 | S3 업로드 감지 → Step Functions 실행 | 선수 직접 작성 |

---

## A. 성적 처리 함수

### 기본 정보

| 항목 | 값 |
|------|-----|
| Runtime | Python 3.12 |
| Handler | index.handler |
| 제공 파일 | `lambda-function.py` |

> 제공된 코드의 `TODO` 부분을 완성하여 배포하세요.

---

### 환경 변수

| Key | Value |
|-----|-------|
| `S3_BUCKET` | 학생 성적 CSV 파일이 저장된 S3 버킷 이름 |
| `DDB_TABLE` | 처리된 학생 성적 데이터를 저장할 DynamoDB 테이블 이름 |

---

### 입력 이벤트

Step Functions에서 아래 형식으로 호출됩니다.

```json
{
  "key": "input/test.csv"
}
```

| 항목 | 조건 |
|------|------|
| `key` | 필수, `"input/"`으로 시작해야 함 |
| Bucket | 환경 변수 `S3_BUCKET`에서 참조 |

---

### 처리 흐름

```
1. S3에서 CSV 파일 읽기
         ↓
2. 각 행 데이터 검증
         ↓
3. 정상 → 평균 점수 계산 → 등급 산출 → DynamoDB 저장
   오류 → S3 error/ 경로에 JSON 저장
```

---

### CSV 검증 규칙

| 조건 | 실패 사유 |
|------|-----------|
| 필수 필드 누락 | `MISSING_FIELD` |
| 점수가 0~100 범위 초과 | `INVALID_SCORE` |
| 점수가 정수 형식이 아님 | `INVALID_FORMAT` |
| examDate가 YYYY-MM-DD 형식이 아님 | `INVALID_DATE` |

---

### 등급 기준

| 평균 점수 | 등급 |
|-----------|------|
| 90 ~ 100 | A |
| 80 ~ 89 | B |
| 70 ~ 79 | C |
| 60 ~ 69 | D |
| 0 ~ 59 | F |

---

### 출력 형식

```json
{
  "statusCode": 200,
  "processed": 5,
  "errors": 4
}
```

| 필드 | 타입 | 설명 |
|------|------|------|
| `statusCode` | int | 200 (정상) / 400 (입력 오류) |
| `processed` | int | 정상 처리된 학생 수 |
| `errors` | int | 검증 실패 학생 수 |

---

### Error JSON 저장

검증 실패 데이터는 아래 형식으로 S3 `error/` 경로에 저장됩니다.

**파일명 규칙**
```
error/{error_timestamp}_{studentId}.json
```

**파일 내용**
```json
{
  "studentId": "STU2002",
  "examDate": "2026-05-30",
  "error_reason": "INVALID_FORMAT",
  "raw_data": {
    "studentId": "STU2002",
    "name": "임은석",
    "className": "1-E",
    "korean": "82",
    "english": "eighty",
    "math": "79",
    "science": "85",
    "history": "88",
    "examDate": "2026-05-30"
  }
}
```

---

## B. 트리거 함수

### 기본 정보

| 항목 | 값 |
|------|-----|
| Runtime | Python 3.12 |
| Handler | 선수 지정 |
| 제공 파일 | 없음 (선수 직접 작성) |

---

### 동작 요구사항

S3 버킷의 `/input/` 경로에 `.csv` 파일이 업로드(PutObject)되면, Step Functions State Machine을 자동으로 실행합니다.

---

### 트리거 설정

- S3 Event Notification을 통해 Lambda가 호출되어야 합니다.
- Prefix: `input/`
- Suffix: `.csv`
- Event Type: `s3:ObjectCreated:*`

---

### 실행 동작

1. S3 이벤트에서 업로드된 파일의 `key`를 추출합니다.
2. Step Functions State Machine을 실행합니다.
3. 실행 입력 형식:

```json
{
  "key": "input/test.csv"
}
```

---

### 참고 사항

- `boto3.client('stepfunctions').start_execution()` 을 사용합니다.
- State Machine ARN은 환경변수로 관리하는 것을 권장합니다.
