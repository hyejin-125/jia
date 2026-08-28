import os
import threading
import time

import boto3
from flask import Flask, jsonify

app = Flask(__name__)

AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL", "")
PROCESSING_TIME = float(os.environ.get("PROCESSING_TIME", "3"))

sqs = boto3.client("sqs", region_name=AWS_REGION)

_processed = 0
_lock = threading.Lock()
_stop = threading.Event()


def _consumer_loop() -> None:
    global _processed

    while not _stop.is_set():
        if not SQS_QUEUE_URL:
            time.sleep(1)
            continue

        try:
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
            )
        except Exception:
            time.sleep(1)
            continue

        for message in response.get("Messages", []):
            message_id = message["MessageId"]
            body = message.get("Body", "")
            time.sleep(PROCESSING_TIME)
            try:
                sqs.delete_message(
                    QueueUrl=SQS_QUEUE_URL,
                    ReceiptHandle=message["ReceiptHandle"],
                )
                with _lock:
                    _processed += 1
                print(f"processed message_id={message_id} body={body}", flush=True)
            except Exception as exc:
                print(f"failed message_id={message_id} error={exc}", flush=True)


@app.route("/healthz", methods=["GET"])
def healthz():
    return jsonify({"status": "ok"}), 200


@app.route("/status", methods=["GET"])
def status():
    with _lock:
        count = _processed
    return jsonify({"processed": count, "queue_url": SQS_QUEUE_URL}), 200


if __name__ == "__main__":
    threading.Thread(target=_consumer_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=8080)
