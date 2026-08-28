import json
import os
from urllib.parse import unquote_plus

import boto3


stepfunctions = boto3.client("stepfunctions")


def handler(event, context):
    state_machine_arn = os.environ["STATE_MACHINE_ARN"]
    executions = []

    for record in event.get("Records", []):
        key = unquote_plus(record["s3"]["object"]["key"])
        if not key.startswith("input/") or not key.lower().endswith(".csv"):
            continue

        response = stepfunctions.start_execution(
            stateMachineArn=state_machine_arn,
            input=json.dumps({"key": key}),
        )
        executions.append(response["executionArn"])

    return {"statusCode": 200, "executions": executions}
