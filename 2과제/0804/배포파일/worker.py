import os
import signal
import time
import boto3

running = True

def stop(_signum, _frame):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

region = os.environ.get("AWS_REGION", "us-west-2")
queue_url = os.environ["SQS_QUEUE_URL"]
processing_seconds = int(os.environ.get("PROCESSING_SECONDS", "20"))

sqs = boto3.client("sqs", region_name=region)

while running:
    response = sqs.receive_message(
        QueueUrl=queue_url,
        MaxNumberOfMessages=1,
        WaitTimeSeconds=10,
        VisibilityTimeout=max(processing_seconds + 30, 60),
    )
    messages = response.get("Messages", [])
    if not messages:
        time.sleep(1)
        continue

    for message in messages:
        print(f"received message_id={message.get('MessageId')}", flush=True)
        time.sleep(processing_seconds)
        sqs.delete_message(
            QueueUrl=queue_url,
            ReceiptHandle=message["ReceiptHandle"],
        )
        print(f"deleted message_id={message.get('MessageId')}", flush=True)
