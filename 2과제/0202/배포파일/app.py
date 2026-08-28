import json
import os
import random
import uuid
from datetime import datetime, timezone

import boto3
from flask import Flask, jsonify

app = Flask(__name__)

STREAM_NAME = os.environ.get("STREAM_NAME")
REGION = os.environ.get("AWS_REGION")

if not STREAM_NAME or not REGION:
    raise RuntimeError("STREAM_NAME and AWS_REGION environment variables are required")

kinesis = boto3.client("kinesis", region_name=REGION)

PRODUCTS = [
    {"name": "Laptop", "price": 1200000},
    {"name": "Mouse", "price": 25000},
    {"name": "Keyboard", "price": 55000},
    {"name": "Monitor", "price": 350000},
    {"name": "Headset", "price": 89000},
]


def generate_order():
    product = random.choice(PRODUCTS)
    return {
        "order_id": str(uuid.uuid4()),
        "product_name": product["name"],
        "price": product["price"],
        "quantity": random.randint(1, 5),
        "event_time": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
    }


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"})


@app.route("/order", methods=["POST"])
def create_order():
    order = generate_order()
    kinesis.put_record(
        StreamName=STREAM_NAME,
        Data=json.dumps(order),
        PartitionKey=order["order_id"],
    )
    return jsonify(order), 201


@app.route("/orders/generate", methods=["POST"])
def generate_orders():
    count = 10
    orders = []
    for _ in range(count):
        order = generate_order()
        kinesis.put_record(
            StreamName=STREAM_NAME,
            Data=json.dumps(order),
            PartitionKey=order["order_id"],
        )
        orders.append(order)
    return jsonify({"generated": count, "orders": orders}), 201


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
