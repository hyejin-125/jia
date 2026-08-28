# Lambda

## 개요
EventBridge Rule에 의해 호출되는 Lambda 함수 4개를 직접 개발합니다. 각 함수는 정책 위반 이벤트를 수신하여 자동 복구를 수행하고, SNS Topic에 알림 메시지를 Publish해야 합니다.

## Lambda Functions

| Function Name | Trigger | Action |
|---------------|---------|--------|
| wsc2026-sg-remediation | wsc2026-sg-change-rule (EventBridge) | 위반 인바운드 규칙 삭제 + 알림 |
| wsc2026-role-remediation | wsc2026-role-change-rule (EventBridge) | IAM Role 원복 + 알림 |
| wsc2026-ec2-terminate-alert | wsc2026-ec2-terminate-rule (EventBridge) | 알림 발송 |
| wsc2026-ec2-type-remediation | wsc2026-ec2-type-change-rule (EventBridge) | 인스턴스 타입 원복 + 알림 |

- Runtime: Python 3.12
- Handler: index.handler

## Lambda Function Environment
다음 환경변수들을 함수에 사용해야합니다.

| Function | Environment | Value |
|----------|-------------|-------|
| Every Function | SNS_TOPIC_ARN | SNS Topic ARN |
| wsc2026-sg-remediation | SECURITY_GROUP_ID | EC2 Security Group ID |
| wsc2026-role-remediation | INSTANCE_ID | EC2 Instance ID |
| wsc2026-role-remediation | ROLE_NAME | wsc2026-event-ec2-role |
| wsc2026-ec2-type-remediation | INSTANCE_ID | EC2 Instance ID |
| wsc2026-ec2-type-remediation | INSTANCE_TYPE | t3.micro |

## EventBridge 이벤트 형식

### Security Group 인바운드 규칙 추가 (wsc2026-sg-change-rule)

```json
{
  "source": "aws.ec2",
  "detail-type": "AWS API Call via CloudTrail",
  "detail": {
    "eventSource": "ec2.amazonaws.com",
    "eventName": "AuthorizeSecurityGroupIngress",
    "requestParameters": {
      "groupId": "sg-0123456789abcdef0",
      "ipPermissions": {
        "items": [
          {
            "ipProtocol": "tcp",
            "fromPort": 22,
            "toPort": 22,
            "ipRanges": {
              "items": [{"cidrIp": "0.0.0.0/0"}]
            }
          }
        ]
      }
    }
  }
}
```

### EC2 IAM Role 변경 (wsc2026-role-change-rule)

```json
{
  "source": "aws.ec2",
  "detail-type": "AWS API Call via CloudTrail",
  "detail": {
    "eventSource": "ec2.amazonaws.com",
    "eventName": "AssociateIamInstanceProfile",
    "requestParameters": {
      "AssociateIamInstanceProfileRequest": {
        "IamInstanceProfile": {
          "Name": "unauthorized-role"
        },
        "InstanceId": "i-0123456789abcdef0"
      }
    }
  }
}
```

### EC2 인스턴스 종료 (wsc2026-ec2-terminate-rule)

```json
{
  "source": "aws.ec2",
  "detail-type": "EC2 Instance State-change Notification",
  "detail": {
    "instance-id": "i-0123456789abcdef0",
    "state": "terminated"
  }
}
```

### EC2 인스턴스 타입 변경 (wsc2026-ec2-type-change-rule)

```json
{
  "source": "aws.ec2",
  "detail-type": "AWS API Call via CloudTrail",
  "detail": {
    "eventSource": "ec2.amazonaws.com",
    "eventName": "ModifyInstanceAttribute",
    "requestParameters": {
      "instanceId": "i-0123456789abcdef0",
      "instanceType": {
        "value": "t3.large"
      }
    }
  }
}
```

## SNS Message Form

```json
{
    "event": "SG_INBOUND_ADDED",
    "timestamp": "2026-05-26T15:30:00Z",
    "detail": "Unauthorized inbound rule removed from sg-xxx",
    "action": "RESTORED"
}
```

| Field | Description |
|-------|-------------|
| event | SG_INBOUND_ADDED / ROLE_CHANGED / EC2_TERMINATED / EC2_TYPE_CHANGED |
| timestamp | 이벤트 발생 시각 (ISO 8601) |
| detail | 위반 상세 내용 |
| action | RESTORED / ALERT_ONLY |

## 각 함수별 처리 로직

### wsc2026-sg-remediation
1. EventBridge에서 AuthorizeSecurityGroupIngress API 호출 이벤트 수신
2. Security Group에서 추가된 인바운드 규칙 삭제
3. SNS 알림 발송

### wsc2026-role-remediation
1. EventBridge에서 AssociateIamInstanceProfile API 호출 이벤트 수신
2. 변경된 IAM Instance Profile을 원래 Role(wsc2026-event-ec2-role)로 교체
3. SNS 알림 발송

### wsc2026-ec2-terminate-alert
1. EventBridge에서 EC2 State-change 이벤트 수신 (state: terminated)
2. SNS 알림 발송

### wsc2026-ec2-type-remediation
1. EventBridge에서 ModifyInstanceAttribute API 호출 이벤트 수신
2. EC2 인스턴스를 중지 후 원래 타입(t3.micro)으로 변경, 재시작
3. SNS 알림 발송
