import os
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError
from flask import Flask, jsonify, request

app = Flask(__name__)

AWS_REGION = os.environ.get("AWS_REGION", "ap-southeast-1")
TABLE_NAME = os.environ.get("TABLE_NAME", "bigbae-nosql-reservation-table")
GSI_NAME = os.environ.get("GSI_NAME", "gsi-user-reservations")

table = boto3.resource("dynamodb", region_name=AWS_REGION).Table(TABLE_NAME)


@app.route("/healthcheck", methods=["GET"])
def healthcheck():
    return "", 200


@app.route("/reserve", methods=["POST"])
def reserve():
    body = request.get_json(silent=True) or {}
    train_id = body.get("train_id")
    seat_id = body.get("seat_id")
    user_id = body.get("user_id")

    if not train_id or not seat_id or not user_id:
        return jsonify({"error": "invalid request"}), 400

    reserved_at = datetime.now(timezone.utc).isoformat()

    try:
        response = table.update_item(
            Key={"train_id": train_id, "seat_id": seat_id},
            UpdateExpression=(
                "SET #status = :reserved, #version = if_not_exists(#version, :zero) + :one, "
                "user_id = :user_id, reserved_at = :reserved_at"
            ),
            ConditionExpression="attribute_not_exists(#status) OR #status = :available",
            ExpressionAttributeNames={"#status": "status", "#version": "version"},
            ExpressionAttributeValues={
                ":reserved": "reserved",
                ":available": "available",
                ":zero": 0,
                ":one": 1,
                ":user_id": user_id,
                ":reserved_at": reserved_at,
            },
            ReturnValues="ALL_NEW",
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return jsonify({"error": "already reserved"}), 409
        raise

    item = response["Attributes"]
    return (
        jsonify(
            {
                "status": "reserved",
                "seat_id": seat_id,
                "version": int(item["version"]),
            }
        ),
        200,
    )


@app.route("/cancel", methods=["POST"])
def cancel():
    body = request.get_json(silent=True) or {}
    train_id = body.get("train_id")
    seat_id = body.get("seat_id")
    user_id = body.get("user_id")

    if not train_id or not seat_id or not user_id:
        return jsonify({"error": "invalid request"}), 400

    try:
        table.update_item(
            Key={"train_id": train_id, "seat_id": seat_id},
            UpdateExpression=(
                "SET #status = :available, #version = if_not_exists(#version, :zero) + :one "
                "REMOVE user_id, reserved_at"
            ),
            ConditionExpression="#status = :reserved AND user_id = :user_id",
            ExpressionAttributeNames={"#status": "status", "#version": "version"},
            ExpressionAttributeValues={
                ":available": "available",
                ":reserved": "reserved",
                ":zero": 0,
                ":one": 1,
                ":user_id": user_id,
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return jsonify({"error": "not owner"}), 409
        raise

    return jsonify({"status": "cancelled", "seat_id": seat_id}), 200


@app.route("/seats/<train_id>", methods=["GET"])
def seats(train_id):
    response = table.query(KeyConditionExpression=Key("train_id").eq(train_id))
    items = []
    for item in response.get("Items", []):
        items.append(
            {
                "seat_id": item["seat_id"],
                "status": item.get("status", "available"),
                "user_id": item.get("user_id"),
            }
        )
    return jsonify(items), 200


@app.route("/my-bookings/<user_id>", methods=["GET"])
def my_bookings(user_id):
    response = table.query(
        IndexName=GSI_NAME,
        KeyConditionExpression=Key("user_id").eq(user_id),
    )
    items = []
    for item in response.get("Items", []):
        items.append(
            {
                "train_id": item["train_id"],
                "seat_id": item["seat_id"],
                "reserved_at": item["reserved_at"],
            }
        )
    return jsonify(items), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
