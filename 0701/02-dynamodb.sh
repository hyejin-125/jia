#!/bin/bash
set -x

export AWS_PAGER=""
aws dynamodb create-table \
    --table-name bigbae-nosql-reservation-table \
    --attribute-definitions \
        AttributeName=train_id,AttributeType=S \
        AttributeName=seat_id,AttributeType=S \
        AttributeName=user_id,AttributeType=S \
        AttributeName=reserved_at,AttributeType=S \
    --key-schema \
        AttributeName=train_id,KeyType=HASH \
        AttributeName=seat_id,KeyType=RANGE \
    --global-secondary-indexes '[{
        "IndexName": "gsi-user-reservations",
        "KeySchema": [
            {"AttributeName": "user_id", "KeyType": "HASH"},
            {"AttributeName": "reserved_at", "KeyType": "RANGE"}
        ],
        "Projection": {
            "ProjectionType": "ALL"
        }
    }]' \
    --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
    --billing-mode PAY_PER_REQUEST

aws dynamodb wait table-exists --table-name bigbae-nosql-reservation-table

aws dynamodb update-continuous-backups \
    --table-name bigbae-nosql-reservation-table \
    --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true

sleep 5

aws dynamodb create-table \
    --table-name bigbae-nosql-audit-table \
    --attribute-definitions \
        AttributeName=event_id,AttributeType=S \
    --key-schema \
        AttributeName=event_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST

echo