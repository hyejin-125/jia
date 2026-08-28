# Workflow 명세서

---

## 개요

학생 성적 데이터 처리 과정을 오케스트레이션하는 Step Functions State Machine입니다.  
선수는 아래 명세를 참고하여 직접 Workflow를 작성해야 합니다.

| 항목 | 값 |
|------|-----|
| State Machine Name | `wsc2026-student-score-workflow` |
| State Machine Type | `STANDARD` |

---

## Workflow 구성

```
[Start]
   ↓
[CheckS3File]
   ↓
[ProcessStudentData] ← Lambda 호출
   ↓
[CheckResult] ← Choice
   ├─ statusCode == 200 → [MoveToProcessed] → [End]
   └─ Otherwise         → [MoveToError] → [Fail]
```

---

## Workflow 실행

S3의 `/input/` 디렉토리에 `.csv` 파일이 생성될 경우 워크플로우가 자동으로 실행되어야 합니다.

> 자동 실행은 트리거 Lambda를 통해 구현합니다. (lambda.md 참고)

---

## 입력 형식

워크플로우는 아래 형식의 입력을 받습니다.

```json
{
  "key": "input/test.csv"
}
```

---

## State 상세

### 1. CheckS3File

S3에 입력 파일이 존재하는지 확인합니다.

| 항목 | 값 |
|------|-----|
| Type | Task |
| 동작 | S3 HeadObject API 호출 |
| 성공 | 다음 State로 이동 |
| 실패 | Fail State로 이동 |

---

### 2. ProcessStudentData

성적 처리 Lambda 함수를 호출하여 학생 성적 데이터를 처리합니다.

| 항목 | 값 |
|------|-----|
| Type | Task |
| Resource | 성적 처리 Lambda 함수 |
| 재시도 | 실패 횟수가 늘어날수록 대기 시간이 점점 증가 (Exponential Backoff) |

**Lambda 입력**
```json
{
  "key": "input/test.csv"
}
```

**Lambda 출력**
```json
{
  "statusCode": 200,
  "processed": 5,
  "errors": 4
}
```

---

### 3. CheckResult

Lambda 실행 결과에 따라 분기 처리합니다.

| 항목 | 값 |
|------|-----|
| Type | Choice |

| 조건 | 이동 |
|------|------|
| `statusCode == 200` | MoveToProcessed |
| Otherwise | MoveToError |

---

### 4. MoveToProcessed

처리 완료된 파일을 S3의 `/processed/` 폴더로 이동합니다.

| 항목 | 값 |
|------|-----|
| Type | Task |
| 동작 | S3 CopyObject + DeleteObject |
| 이동 경로 | `input/test.csv` → `processed/test.csv` |
| 완료 후 | End (워크플로우 정상 종료) |

---

### 5. MoveToError

오류 발생 시 파일을 S3의 `/error/` 폴더로 이동합니다.

| 항목 | 값 |
|------|-----|
| Type | Task |
| 동작 | S3 CopyObject + DeleteObject |
| 이동 경로 | `input/test.csv` → `error/test.csv` |
| 완료 후 | Fail (워크플로우 실패 종료) |
