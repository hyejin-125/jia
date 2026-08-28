import csv
import io
import json
import os
import re
from datetime import datetime, timezone
from decimal import Decimal

import boto3

REQUIRED_FIELDS = ["examDate", "studentId", "name", "className", "korean", "english", "math", "science", "history"]
SCORE_FIELDS = ["korean", "english", "math", "science", "history"]

s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")


def validate_row(row):
    for field in REQUIRED_FIELDS:
        if not (row.get(field) or "").strip():
            return "MISSING_FIELD"

    exam_date = row.get("examDate", "").strip()
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", exam_date):
        return "INVALID_DATE"
    try:
        datetime.strptime(exam_date, "%Y-%m-%d")
    except ValueError:
        return "INVALID_DATE"

    for field in SCORE_FIELDS:
        value = row.get(field, "").strip()
        if not value.lstrip("+-").isdigit():
            return "INVALID_FORMAT"
        score = int(value)
        if score < 0 or score > 100:
            return "INVALID_SCORE"

    return None


def save_error(bucket, row, error_reason, timestamp):
    student_id = (row.get("studentId") or "unknown").strip()
    error_key = f"error/error_{timestamp}_{student_id}.json"

    body = {
        "studentId": student_id,
        "examDate": (row.get("examDate") or "").strip(),
        "error_reason": error_reason,
        "raw_data": {k: (v or "").strip() for k, v in row.items()},
    }

    s3_client.put_object(
        Bucket=bucket,
        Key=error_key,
        Body=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        ContentType="application/json; charset=utf-8",
    )


def calculate_grade(average):
    if average >= 90:
        return "A"
    if average >= 80:
        return "B"
    if average >= 70:
        return "C"
    if average >= 60:
        return "D"
    return "F"


def save_student(table, row):
    scores = {field: int(row[field].strip()) for field in SCORE_FIELDS}
    average = Decimal(sum(scores.values())) / Decimal(len(SCORE_FIELDS))

    table.put_item(
        Item={
            "studentId": row["studentId"].strip(),
            "examDate": row["examDate"].strip(),
            "name": row["name"].strip(),
            "className": row["className"].strip(),
            **scores,
            "average": average,
            "grade": calculate_grade(average),
            "createdAt": datetime.now(timezone.utc).isoformat(),
        }
    )


def handler(event, context):
    bucket = os.environ.get("S3_BUCKET")
    table_name = os.environ.get("DDB_TABLE")

    if not bucket or not table_name:
        return {"statusCode": 400, "processed": 0, "errors": 0}

    key = event.get("key")
    if not key or not key.startswith("input/"):
        return {"statusCode": 400, "processed": 0, "errors": 0}

    try:
        response = s3_client.get_object(Bucket=bucket, Key=key)
        csv_text = response["Body"].read().decode("utf-8")
    except Exception:
        return {"statusCode": 400, "processed": 0, "errors": 0}

    reader = csv.DictReader(io.StringIO(csv_text))
    rows = list(reader)

    table = dynamodb.Table(table_name)
    processed = 0
    errors = 0
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")

    for row in rows:
        error_reason = validate_row(row)
        if error_reason:
            save_error(bucket, row, error_reason, timestamp)
            errors += 1
        else:
            save_student(table, row)
            processed += 1

    return {"statusCode": 200, "processed": processed, "errors": errors}
