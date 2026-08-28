#!/bin/bash
set -x

rm -rf ~/.aws
export AWS_PAGER=""
aws configure set cli_binary_format raw-in-base64-out
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="skillsphone-landing-ab-$ACCOUNT_ID"

aws s3 mb s3://$BUCKET_NAME
aws s3api put-object --bucket $BUCKET_NAME --key "version-a/" >/dev/null
aws s3api put-object --bucket $BUCKET_NAME --key "version-b/" >/dev/null

cat << EOF > oac-config.json
{
    "OriginAccessControlConfig": {
        "Name": "skillsphone-oac-${ACCOUNT_ID}",
        "Description": "OAC for S3 skillsphone landing",
        "OriginAccessControlOriginType": "s3",
        "SigningBehavior": "always",
        "SigningProtocol": "sigv4"
    }
}
EOF

OAC_ID=$(aws cloudfront create-origin-access-control \
    --cli-input-json file://oac-config.json \
    --query 'OriginAccessControl.Id' \
    --output text 2>/dev/null || aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='skillsphone-oac-${ACCOUNT_ID}'].Id | [0]" \
    --output text)

cat << EOF > dist-config.json
{
  "CallerReference": "skillsphone-cdn-ab-distribution-$(date +%s)",
  "Comment": "skillsphone-cdn-ab-distribution",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "S3-${BUCKET_NAME}",
        "DomainName": "${BUCKET_NAME}.s3.amazonaws.com",
        "OriginAccessControlId": "${OAC_ID}",
        "S3OriginConfig": {
          "OriginAccessIdentity": ""
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3-${BUCKET_NAME}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "MinTTL": 0,
    "DefaultTTL": 3600,
    "MaxTTL": 86400,
    "ForwardedValues": {
      "QueryString": false,
      "Cookies": {
        "Forward": "none"
      }
    }
  }
}
EOF

aws cloudfront create-distribution --distribution-config file://dist-config.json > /dev/null

sleep 5

CF_ARN=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='skillsphone-cdn-ab-distribution'].ARN | [0]" --output text)

CF_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?ARN=='$CF_ARN'].Id" --output text)
aws cloudfront tag-resource \
    --resource $CF_ARN \
    --tags '{"Items": [{"Key": "Name", "Value": "skillsphone-cdn-ab-distribution"}]}'
    
cat << EOF > s3-policy.json
{
    "Version": "2008-10-17",
    "Id": "PolicyForCloudFrontPrivateContent",
    "Statement": [
        {
            "Sid": "AllowCloudFrontServicePrincipal",
            "Effect": "Allow",
            "Principal": {
                "Service": "cloudfront.amazonaws.com"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::$BUCKET_NAME/*",
            "Condition": {
                "StringEquals": {
                    "AWS:SourceArn": "$CF_ARN"
                }
            }
        }
    ]
}
EOF

aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy file://s3-policy.json

rm -f oac-config.json dist-config.json s3-policy.json

echo