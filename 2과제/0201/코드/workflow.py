#!/usr/bin/env python3
import io
import json
import os
import sys
import time
import urllib.parse
import zipfile
from pathlib import Path

import boto3
from botocore.exceptions import ClientError


REGION = "ap-southeast-1"
TABLE_NAME = "wsc2026-student-score"
PROCESSOR_NAME = "wsc2026-student-score-function"
TRIGGER_NAME = "wsc2026-student-score-trigger"
LAMBDA_ROLE_NAME = "wsc2026-lambda-student-role"
SFN_ROLE_NAME = "wsc2026-stepfunction-student-role"
STATE_MACHINE_NAME = "wsc2026-student-score-workflow"
ROOT = Path(__file__).resolve().parent


def ensure_lambda(client, name, role_arn, code, environment):
    kwargs = {
        "FunctionName": name,
        "Role": role_arn,
        "Runtime": "python3.12",
        "Handler": "index.handler",
        "Timeout": 60,
        "MemorySize": 256,
        "Environment": {"Variables": environment},
    }
    try:
        response = client.get_function(FunctionName=name)
        client.update_function_code(
            FunctionName=name, ZipFile=code, Publish=True
        )
        client.get_waiter("function_updated").wait(FunctionName=name)
        client.update_function_configuration(**kwargs)
        client.get_waiter("function_updated").wait(FunctionName=name)
        return response["Configuration"]["FunctionArn"]
    except client.exceptions.ResourceNotFoundException:
        for attempt in range(10):
            try:
                return client.create_function(
                    **kwargs,
                    Code={"ZipFile": code},
                    Publish=True,
                    Tags={"Name": name},
                )["FunctionArn"]
            except ClientError as exc:
                error_code = exc.response.get("Error", {}).get("Code", "")
                error_msg = str(exc)
                if error_code == "InvalidParameterValueException" and "cannot be assumed by Lambda" in error_msg and attempt < 9:
                    time.sleep(3)
                    continue
                raise

def zip_code(filename, arcname="index.py"):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(ROOT / filename, arcname)
    return output.getvalue()


def wait_for_role(iam, role_name):
    for _ in range(30):
        try:
            iam.get_role(RoleName=role_name)
            time.sleep(8)
            return
        except ClientError:
            time.sleep(2)
    raise TimeoutError(f"IAM role was not ready: {role_name}")


def ensure_role(iam, name, service, policy):
    trust = {
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": service},
            "Action": "sts:AssumeRole",
        }],
    }
    try:
        role = iam.get_role(RoleName=name)["Role"]
        iam.update_assume_role_policy(
            RoleName=name, PolicyDocument=json.dumps(trust)
        )
    except iam.exceptions.NoSuchEntityException:
        role = iam.create_role(
            RoleName=name,
            AssumeRolePolicyDocument=json.dumps(trust),
            Tags=[{"Key": "Name", "Value": name}],
        )["Role"]
    iam.put_role_policy(
        RoleName=name,
        PolicyName=f"{name}-least-privilege",
        PolicyDocument=json.dumps(policy),
    )
    wait_for_role(iam, name)
    return role["Arn"]


def ensure_bucket(s3, bucket):
    try:
        s3.head_bucket(Bucket=bucket)
    except ClientError as exc:
        if exc.response["Error"]["Code"] not in ("404", "NoSuchBucket"):
            raise
        
        for attempt in range(5):
            try:
                s3.create_bucket(
                    Bucket=bucket,
                    CreateBucketConfiguration={"LocationConstraint": REGION},
                )
                break
            except ClientError as create_exc:
                error_code = create_exc.response.get("Error", {}).get("Code", "")
                if error_code == "OperationAborted" and attempt < 4:
                    time.sleep(3)
                    continue
                raise

    s3.put_public_access_block(
        Bucket=bucket,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
    s3.put_bucket_tagging(
        Bucket=bucket,
        Tagging={"TagSet": [{"Key": "Name", "Value": bucket}]},
    )
    s3.put_bucket_notification_configuration(
        Bucket=bucket, NotificationConfiguration={}
    )


def ensure_table(dynamodb):
    try:
        table = dynamodb.Table(TABLE_NAME)
        table.load()
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ResourceNotFoundException":
            raise
        table = dynamodb.create_table(
            TableName=TABLE_NAME,
            BillingMode="PAY_PER_REQUEST",
            KeySchema=[
                {"AttributeName": "studentId", "KeyType": "HASH"},
                {"AttributeName": "examDate", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "studentId", "AttributeType": "S"},
                {"AttributeName": "examDate", "AttributeType": "S"},
            ],
            Tags=[{"Key": "Name", "Value": TABLE_NAME}],
        )
        table.wait_until_exists()
    return table


def ensure_lambda(client, name, role_arn, code, environment):
    kwargs = {
        "FunctionName": name,
        "Role": role_arn,
        "Runtime": "python3.12",
        "Handler": "index.handler",
        "Timeout": 60,
        "MemorySize": 256,
        "Environment": {"Variables": environment},
    }
    try:
        response = client.get_function(FunctionName=name)
        client.update_function_code(
            FunctionName=name, ZipFile=code, Publish=True
        )
        client.get_waiter("function_updated").wait(FunctionName=name)
        client.update_function_configuration(**kwargs)
        client.get_waiter("function_updated").wait(FunctionName=name)
        return response["Configuration"]["FunctionArn"]
    except client.exceptions.ResourceNotFoundException:
        return client.create_function(
            **kwargs,
            Code={"ZipFile": code},
            Publish=True,
            Tags={"Name": name},
        )["FunctionArn"]


def state_machine_definition(bucket, processor_arn):
    destination_name = (
        "States.ArrayGetItem(States.StringSplit($.key, '/'), 1)"
    )
    copy_source = f"States.Format('{bucket}/{{}}', $.key)"
    return {
        "Comment": "Student score CSV processing workflow",
        "StartAt": "CheckS3File",
        "States": {
            "CheckS3File": {
                "Type": "Task",
                "Resource": "arn:aws:states:::aws-sdk:s3:headObject",
                "Parameters": {"Bucket": bucket, "Key.$": "$.key"},
                "ResultPath": None,
                "Next": "ProcessStudentData",
                "Catch": [{"ErrorEquals": ["States.ALL"], "Next": "FileNotFound"}],
            },
            "ProcessStudentData": {
                "Type": "Task",
                "Resource": "arn:aws:states:::lambda:invoke",
                "Parameters": {
                    "FunctionName": processor_arn,
                    "Payload.$": "$",
                },
                "ResultPath": "$.lambda",
                "Retry": [{
                    "ErrorEquals": [
                        "Lambda.ServiceException",
                        "Lambda.AWSLambdaException",
                        "Lambda.SdkClientException",
                        "Lambda.TooManyRequestsException",
                    ],
                    "IntervalSeconds": 2,
                    "BackoffRate": 2.0,
                    "MaxAttempts": 3,
                }],
                "Catch": [{
                    "ErrorEquals": ["States.ALL"],
                    "ResultPath": "$.lambdaError",
                    "Next": "MoveToError",
                }],
                "Next": "CheckResult",
            },
            "CheckResult": {
                "Type": "Choice",
                "Choices": [{
                    "Variable": "$.lambda.Payload.statusCode",
                    "NumericEquals": 200,
                    "Next": "MoveToProcessed",
                }],
                "Default": "MoveToError",
            },
            "MoveToProcessed": {
                "Type": "Task",
                "Resource": "arn:aws:states:::aws-sdk:s3:copyObject",
                "Parameters": {
                    "Bucket": bucket,
                    "CopySource.$": copy_source,
                    "Key.$": f"States.Format('processed/{{}}', {destination_name})",
                },
                "ResultPath": None,
                "Next": "DeleteProcessedSource",
            },
            "DeleteProcessedSource": {
                "Type": "Task",
                "Resource": "arn:aws:states:::aws-sdk:s3:deleteObject",
                "Parameters": {"Bucket": bucket, "Key.$": "$.key"},
                "End": True,
            },
            "MoveToError": {
                "Type": "Task",
                "Resource": "arn:aws:states:::aws-sdk:s3:copyObject",
                "Parameters": {
                    "Bucket": bucket,
                    "CopySource.$": copy_source,
                    "Key.$": f"States.Format('error/{{}}', {destination_name})",
                },
                "ResultPath": None,
                "Next": "DeleteErrorSource",
            },
            "DeleteErrorSource": {
                "Type": "Task",
                "Resource": "arn:aws:states:::aws-sdk:s3:deleteObject",
                "Parameters": {"Bucket": bucket, "Key.$": "$.key"},
                "Next": "ProcessingFailed",
            },
            "FileNotFound": {
                "Type": "Fail",
                "Error": "S3FileNotFound",
                "Cause": "The input object does not exist.",
            },
            "ProcessingFailed": {
                "Type": "Fail",
                "Error": "StudentDataProcessingFailed",
                "Cause": "The processor returned an error.",
            },
        },
    }


def ensure_state_machine(sfn, role_arn, definition):
    existing = sfn.list_state_machines()["stateMachines"]
    match = next((s for s in existing if s["name"] == STATE_MACHINE_NAME), None)
    if match:
        sfn.update_state_machine(
            stateMachineArn=match["stateMachineArn"],
            definition=json.dumps(definition),
            roleArn=role_arn,
        )
        return match["stateMachineArn"]
    return sfn.create_state_machine(
        name=STATE_MACHINE_NAME,
        definition=json.dumps(definition),
        roleArn=role_arn,
        type="STANDARD",
        tags=[{"key": "Name", "value": STATE_MACHINE_NAME}],
    )["stateMachineArn"]


def clear_bucket(s3, bucket):
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket):
        objects = [{"Key": item["Key"]} for item in page.get("Contents", [])]
        if objects:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": objects})


def clear_table(table):
    scan = table.scan(ProjectionExpression="studentId, examDate")
    while True:
        with table.batch_writer() as batch:
            for item in scan["Items"]:
                batch.delete_item(Key=item)
        if "LastEvaluatedKey" not in scan:
            break
        scan = table.scan(
            ProjectionExpression="studentId, examDate",
            ExclusiveStartKey=scan["LastEvaluatedKey"],
        )


def wait_for_execution(sfn, execution_arn):
    for _ in range(90):
        result = sfn.describe_execution(executionArn=execution_arn)
        if result["status"] in ("SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"):
            return result
        time.sleep(2)
    raise TimeoutError("Step Functions execution did not finish")


def allow_s3_invoke(lambda_client, trigger_arn, bucket, account_id):
    try:
        lambda_client.remove_permission(
            FunctionName=TRIGGER_NAME, StatementId="AllowS3Invoke"
        )
    except lambda_client.exceptions.ResourceNotFoundException:
        pass
    lambda_client.add_permission(
        FunctionName=TRIGGER_NAME,
        StatementId="AllowS3Invoke",
        Action="lambda:InvokeFunction",
        Principal="s3.amazonaws.com",
        SourceArn=f"arn:aws:s3:::{bucket}",
        SourceAccount=account_id,
    )


def main():
    session = boto3.Session(region_name=REGION)
    sts = session.client("sts")
    account_id = sts.get_caller_identity()["Account"]
    suffix = os.environ.get("CANDIDATE_NUMBER").lower()
    bucket = f"wsc2026-student-score-bucket-{suffix}"

    iam = session.client("iam")
    s3 = session.client("s3")
    dynamodb = session.resource("dynamodb")
    lambda_client = session.client("lambda")
    sfn = session.client("stepfunctions")

    ensure_bucket(s3, bucket)
    table = ensure_table(dynamodb)

    lambda_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "WriteLogs",
                "Effect": "Allow",
                "Action": [
                    "logs:CreateLogGroup",
                    "logs:CreateLogStream",
                    "logs:PutLogEvents",
                ],
                "Resource": f"arn:aws:logs:{REGION}:{account_id}:*",
            },
            {
                "Sid": "ReadInputWriteErrors",
                "Effect": "Allow",
                "Action": ["s3:GetObject", "s3:PutObject"],
                "Resource": [
                    f"arn:aws:s3:::{bucket}/input/*",
                    f"arn:aws:s3:::{bucket}/error/*",
                ],
            },
            {
                "Sid": "WriteScores",
                "Effect": "Allow",
                "Action": "dynamodb:PutItem",
                "Resource": f"arn:aws:dynamodb:{REGION}:{account_id}:table/{TABLE_NAME}",
            },
            {
                "Sid": "StartWorkflow",
                "Effect": "Allow",
                "Action": "states:StartExecution",
                "Resource": f"arn:aws:states:{REGION}:{account_id}:stateMachine:{STATE_MACHINE_NAME}",
            },
        ],
    }
    lambda_role_arn = ensure_role(
        iam, LAMBDA_ROLE_NAME, "lambda.amazonaws.com", lambda_policy
    )

    processor_arn = ensure_lambda(
        lambda_client,
        PROCESSOR_NAME,
        lambda_role_arn,
        zip_code("stepfunction_app.py"),
        {"S3_BUCKET": bucket, "DDB_TABLE": TABLE_NAME},
    )

    sfn_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "S3Workflow",
                "Effect": "Allow",
                "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
                "Resource": f"arn:aws:s3:::{bucket}/*",
            },
            {
                "Sid": "InvokeProcessor",
                "Effect": "Allow",
                "Action": "lambda:InvokeFunction",
                "Resource": processor_arn,
            },
        ],
    }

    sfn_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "S3Workflow",
                "Effect": "Allow",
                "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
                "Resource": f"arn:aws:s3:::{bucket}/*",
            },
            {
                "Sid": "InvokeProcessor",
                "Effect": "Allow",
                "Action": "lambda:InvokeFunction",
                "Resource": processor_arn,
            },
        ],
    }
    sfn_role_arn = ensure_role(
        iam, SFN_ROLE_NAME, "states.amazonaws.com", sfn_policy
    )
    definition = state_machine_definition(bucket, processor_arn)
    state_machine_arn = ensure_state_machine(sfn, sfn_role_arn, definition)

    trigger_arn = ensure_lambda(
        lambda_client,
        TRIGGER_NAME,
        lambda_role_arn,
        zip_code("stepfunction_trigger.py"),
        {"STATE_MACHINE_ARN": state_machine_arn},
    )
    allow_s3_invoke(lambda_client, trigger_arn, bucket, account_id)
    time.sleep(10)

    clear_bucket(s3, bucket)
    clear_table(table)
    test_body = (ROOT / "test.csv").read_bytes()
    s3.put_object(Bucket=bucket, Key="input/test.csv", Body=test_body)
    execution = sfn.start_execution(
        stateMachineArn=state_machine_arn,
        input=json.dumps({"key": "input/test.csv"}),
    )
    result = wait_for_execution(sfn, execution["executionArn"])
    if result["status"] != "SUCCEEDED":
        print(json.dumps(result, default=str, indent=2))
        raise RuntimeError("End-to-end workflow test failed")

    item_count = table.scan(Select="COUNT")["Count"]
    error_count = sum(
        page.get("KeyCount", 0)
        for page in s3.get_paginator("list_objects_v2").paginate(
            Bucket=bucket, Prefix="error/"
        )
    )
    if item_count != 5 or error_count != 4:
        raise RuntimeError(
            f"Unexpected test result: DynamoDB={item_count}, errors={error_count}"
        )

    s3.put_object(Bucket=bucket, Key="input/", Body=b"")
    s3.put_bucket_notification_configuration(
        Bucket=bucket,
        NotificationConfiguration={
            "LambdaFunctionConfigurations": [{
                "Id": "StartStudentScoreWorkflow",
                "LambdaFunctionArn": trigger_arn,
                "Events": ["s3:ObjectCreated:*"],
                "Filter": {
                    "Key": {
                        "FilterRules": [
                            {"Name": "prefix", "Value": "input/"},
                            {"Name": "suffix", "Value": ".csv"},
                        ]
                    }
                },
            }]
        },
    )

    print(json.dumps({
        "status": "DEPLOYED_AND_VERIFIED",
        "region": REGION,
        "bucket": bucket,
        "table": TABLE_NAME,
        "processor": PROCESSOR_NAME,
        "trigger": TRIGGER_NAME,
        "stateMachineArn": state_machine_arn,
        "testResult": {"processed": 5, "errors": 4},
        "finalState": {
            "input/": "prefix marker present",
            "processed/test.csv": "present",
            "error/": "4 validation files",
            "DynamoDB": "5 valid items",
        },
    }, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"DEPLOYMENT_FAILED: {exc}", file=sys.stderr)
        raise
