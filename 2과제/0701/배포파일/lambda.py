import os
import uuid
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.types import TypeDeserializer

AUDIT_TABLE_NAME = os.environ.get("AUDIT_TABLE_NAME", "bigbae-nosql-audit-table")

dynamodb = boto3.resource("dynamodb")
audit_table = dynamodb.Table(AUDIT_TABLE_NAME)
_deserializer = TypeDeserializer()


def _deserialize_image(image: dict | None) -> dict:
    if not image:
        return {}
    return {key: _deserializer.deserialize(value) for key, value in image.items()}


def handler(event, context):
    for record in event.get("Records", []):
        new_image = _deserialize_image(record["dynamodb"].get("NewImage"))
        old_image = _deserialize_image(record["dynamodb"].get("OldImage"))
        image = new_image or old_image

        audit_table.put_item(
            Item={
                "event_id": str(uuid.uuid4()),
                "train_id": image.get("train_id"),
                "seat_id": image.get("seat_id"),
                "user_id": image.get("user_id"),
                "occurred_at": datetime.now(timezone.utc).isoformat(),
                "stream_event": record.get("eventName"),
                "old_status": old_image.get("status"),
                "new_status": new_image.get("status"),
            }
        )

    return {"statusCode": 200}
