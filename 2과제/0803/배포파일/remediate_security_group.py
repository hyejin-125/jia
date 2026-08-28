import json
import os
import time
from typing import Any, Dict, List, Optional

import boto3
from botocore.exceptions import ClientError


ec2 = boto3.client("ec2")
sns = boto3.client("sns")


def _find_first_group_id(value: Any) -> Optional[str]:
    if isinstance(value, dict):
        for key in ("groupId", "GroupId", "groupID"):
            item = value.get(key)
            if isinstance(item, str) and item.startswith("sg-"):
                return item
        for item in value.values():
            found = _find_first_group_id(item)
            if found:
                return found
    if isinstance(value, list):
        for item in value:
            found = _find_first_group_id(item)
            if found:
                return found
    return None


def _extract_group_id(event: Dict[str, Any]) -> Optional[str]:
    detail = event.get("detail", {})
    request_parameters = detail.get("requestParameters", {})
    response_elements = detail.get("responseElements", {})
    return _find_first_group_id(request_parameters) or _find_first_group_id(response_elements)


def _describe_ingress_permissions(group_id: str) -> List[Dict[str, Any]]:
    response = ec2.describe_security_groups(GroupIds=[group_id])
    groups = response.get("SecurityGroups", [])
    if not groups:
        return []
    return groups[0].get("IpPermissions", [])


def _revoke_all_ingress(group_id: str, permissions: List[Dict[str, Any]]) -> int:
    if not permissions:
        return 0
    ec2.revoke_security_group_ingress(GroupId=group_id, IpPermissions=permissions)
    return len(permissions)


def _publish(topic_arn: str, payload: Dict[str, Any]) -> None:
    subject = "Security Group remediated"
    sns.publish(TopicArn=topic_arn, Subject=subject, Message=json.dumps(payload, ensure_ascii=False, indent=2, default=str))


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    protected_group_id = os.environ["PROTECTED_SECURITY_GROUP_ID"]
    topic_arn = os.environ["SNS_TOPIC_ARN"]

    event_name = event.get("detail", {}).get("eventName", "")
    event_group_id = _extract_group_id(event)
    request_id = event.get("detail", {}).get("requestID", "")

    if event_group_id != protected_group_id:
        result = {
            "status": "IGNORED",
            "reason": "event is not for the protected security group",
            "eventName": event_name,
            "eventGroupId": event_group_id,
            "protectedGroupId": protected_group_id,
            "requestId": request_id,
            "timestamp": int(time.time()),
        }
        print(json.dumps(result, ensure_ascii=False, default=str))
        return result

    permissions = _describe_ingress_permissions(protected_group_id)
    revoked_count = 0
    publish_status = "NOT_REQUIRED"

    try:
        revoked_count = _revoke_all_ingress(protected_group_id, permissions)
        status = "RESTORED" if revoked_count else "NO_ACTION"
    except ClientError as exc:
        result = {
            "status": "REMEDIATION_FAILED",
            "eventName": event_name,
            "eventGroupId": event_group_id,
            "protectedGroupId": protected_group_id,
            "requestId": request_id,
            "error": str(exc),
            "timestamp": int(time.time()),
        }
        print(json.dumps(result, ensure_ascii=False, default=str))
        raise

    result = {
        "status": status,
        "eventName": event_name,
        "eventGroupId": event_group_id,
        "protectedGroupId": protected_group_id,
        "requestId": request_id,
        "revokedPermissionCount": revoked_count,
        "timestamp": int(time.time()),
    }

    try:
        _publish(topic_arn, result)
        publish_status = "SNS_PUBLISHED"
    except Exception as exc:
        publish_status = "SNS_PUBLISH_FAILED"
        result["snsError"] = str(exc)

    result["publishStatus"] = publish_status
    print(json.dumps(result, ensure_ascii=False, default=str))
    return result
