import json
import os
from datetime import datetime, timezone

import boto3

ec2_client = boto3.client("ec2")
iam_client = boto3.client("iam")
sns_client = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")


def publish_alert(event_type, detail, action):
    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Message=json.dumps({
            "event": event_type,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "detail": detail,
            "action": action,
        }),
    )


# ===== wsc2026-sg-remediation =====
def sg_remediation_handler(event, context):
    sg_id = os.environ.get("SECURITY_GROUP_ID")
    detail = event.get("detail", {})
    request_params = detail.get("requestParameters", {})

    # TODO: Security Group에서 추가된 인바운드 규칙을 삭제하는 로직 구현
    # ec2_client.revoke_security_group_ingress()를 사용하세요
    # requestParameters의 ipPermissions에서 추가된 규칙 정보를 추출하세요

    publish_alert(
        "SG_INBOUND_ADDED",
        f"Unauthorized inbound rule removed from {sg_id}",
        "RESTORED",
    )


# ===== wsc2026-role-remediation =====
def role_remediation_handler(event, context):
    instance_id = os.environ.get("INSTANCE_ID")
    role_name = os.environ.get("ROLE_NAME")
    detail = event.get("detail", {})

    # TODO: 변경된 IAM Instance Profile을 원래 Role로 교체하는 로직 구현
    # 1. ec2_client.describe_iam_instance_profile_associations()로 현재 연결 확인
    # 2. ec2_client.replace_iam_instance_profile_association()으로 원래 Role로 교체

    publish_alert(
        "ROLE_CHANGED",
        f"IAM role on instance {instance_id} was changed and restored to {role_name}",
        "RESTORED",
    )


# ===== wsc2026-ec2-terminate-alert =====
def ec2_terminate_handler(event, context):
    detail = event.get("detail", {})
    instance_id = detail.get("instance-id", "unknown")

    # TODO: SNS 알림을 발송하는 로직 구현
    # publish_alert()를 사용하여 EC2_TERMINATED 이벤트 알림을 발송하세요
    # action은 "ALERT_ONLY"


# ===== wsc2026-ec2-type-remediation =====
def ec2_type_remediation_handler(event, context):
    instance_id = os.environ.get("INSTANCE_ID")
    original_type = os.environ.get("INSTANCE_TYPE")
    detail = event.get("detail", {})

    # TODO: EC2 인스턴스 타입을 원래대로 복구하는 로직 구현
    # 1. ec2_client.stop_instances()로 인스턴스 중지
    # 2. waiter로 중지 완료 대기
    # 3. ec2_client.modify_instance_attribute()로 타입 변경
    # 4. ec2_client.start_instances()로 인스턴스 시작

    publish_alert(
        "EC2_TYPE_CHANGED",
        f"Instance {instance_id} type was changed and restored to {original_type}",
        "RESTORED",
    )
