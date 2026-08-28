#!/bin/bash
set -x

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="ap-northeast-2"

CLUSTER_NAME=skm-eks-cluster
APP_NS=skillsmkt
KARPENTER_NS=kube-system
KEDA_NS=keda
SQS_QUEUE_NAME=skm-order-queue

OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

cat > /tmp/app-sqs-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ],
      "Resource": "arn:aws:sqs:${REGION}:${ACCOUNT_ID}:${SQS_QUEUE_NAME}"
    }
  ]
}
EOF

APP_POLICY_ARN=$(aws iam create-policy \
  --policy-name skm-app-sqs-policy \
  --policy-document file:///tmp/app-sqs-policy.json \
  --query 'Policy.Arn' --output text 2>/dev/null || \
  aws iam get-policy \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/skm-app-sqs-policy" \
    --query 'Policy.Arn' --output text)

cat > /tmp/app-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${APP_NS}:order-processor-sa",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name skm-app-sqs-role \
  --assume-role-policy-document file:///tmp/app-trust.json \
  --output text 2>/dev/null || echo "Role already exists"

aws iam attach-role-policy \
  --role-name skm-app-sqs-role \
  --policy-arn $APP_POLICY_ARN

APP_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/skm-app-sqs-role"

cat > /tmp/keda-sqs-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ],
      "Resource": "arn:aws:sqs:${REGION}:${ACCOUNT_ID}:${SQS_QUEUE_NAME}"
    }
  ]
}
EOF

KEDA_POLICY_ARN=$(aws iam create-policy \
  --policy-name skm-keda-sqs-policy \
  --policy-document file:///tmp/keda-sqs-policy.json \
  --query 'Policy.Arn' --output text 2>/dev/null || \
  aws iam get-policy \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/skm-keda-sqs-policy" \
    --query 'Policy.Arn' --output text)

cat > /tmp/keda-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${KEDA_NS}:keda-operator",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name skm-keda-sqs-role \
  --assume-role-policy-document file:///tmp/keda-trust.json \
  --output text 2>/dev/null || echo "Role already exists"

aws iam attach-role-policy \
  --role-name skm-keda-sqs-role \
  --policy-arn $KEDA_POLICY_ARN

KEDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/skm-keda-sqs-role"

cat > /tmp/karpenter-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowScopedEC2InstanceActions",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateFleet"
      ],
      "Resource": [
        "arn:aws:ec2:${REGION}::image/*",
        "arn:aws:ec2:${REGION}::snapshot/*",
        "arn:aws:ec2:${REGION}:*:security-group/*",
        "arn:aws:ec2:${REGION}:*:subnet/*",
        "arn:aws:ec2:${REGION}:*:launch-template/*",
        "arn:aws:ec2:${REGION}:*:network-interface/*",
        "arn:aws:ec2:${REGION}:*:key-pair/*",
        "arn:aws:ec2:${REGION}:*:instance/*",
        "arn:aws:ec2:${REGION}:*:volume/*"
      ]
    },
    {
      "Sid": "AllowScopedEC2InstanceActionsWithTags",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateFleet",
        "ec2:CreateLaunchTemplate"
      ],
      "Resource": [
        "arn:aws:ec2:${REGION}:*:fleet/*",
        "arn:aws:ec2:${REGION}:*:instance/*",
        "arn:aws:ec2:${REGION}:*:volume/*",
        "arn:aws:ec2:${REGION}:*:network-interface/*",
        "arn:aws:ec2:${REGION}:*:launch-template/*",
        "arn:aws:ec2:${REGION}:*:spot-instances-request/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned"
        },
        "StringLike": {
          "aws:RequestTag/karpenter.sh/nodepool": "*"
        }
      }
    },
    {
      "Sid": "AllowScopedResourceCreationTagging",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": [
        "arn:aws:ec2:${REGION}:*:fleet/*",
        "arn:aws:ec2:${REGION}:*:instance/*",
        "arn:aws:ec2:${REGION}:*:volume/*",
        "arn:aws:ec2:${REGION}:*:network-interface/*",
        "arn:aws:ec2:${REGION}:*:launch-template/*",
        "arn:aws:ec2:${REGION}:*:spot-instances-request/*"
      ],
      "Condition": {
        "StringEquals": {
          "ec2:CreateAction": [
            "RunInstances",
            "CreateFleet",
            "CreateLaunchTemplate"
          ]
        }
      }
    },
    {
      "Sid": "AllowScopedResourceTagging",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "arn:aws:ec2:${REGION}:*:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.sh/nodepool": "*"
        },
        "ForAllValues:StringEquals": {
          "aws:TagKeys": [
            "karpenter.sh/nodeclaim",
            "Name"
          ]
        }
      }
    },
    {
      "Sid": "AllowScopedDeletion",
      "Effect": "Allow",
      "Action": [
        "ec2:TerminateInstances",
        "ec2:DeleteLaunchTemplate"
      ],
      "Resource": [
        "arn:aws:ec2:${REGION}:*:instance/*",
        "arn:aws:ec2:${REGION}:*:launch-template/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.sh/nodepool": "*"
        }
      }
    },
    {
      "Sid": "AllowRegionalReadActions",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "${REGION}"
        }
      }
    },
    {
      "Sid": "AllowSSMReadActions",
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:${REGION}::parameter/aws/service/*"
    },
    {
      "Sid": "AllowPricingReadActions",
      "Effect": "Allow",
      "Action": "pricing:GetProducts",
      "Resource": "*"
    },
    {
      "Sid": "AllowInterruptionQueueActions",
      "Effect": "Allow",
      "Action": [
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ReceiveMessage"
      ],
      "Resource": "arn:aws:sqs:${REGION}:${ACCOUNT_ID}:${CLUSTER_NAME}"
    },
    {
      "Sid": "AllowPassingInstanceRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    },
    {
      "Sid": "AllowScopedInstanceProfileCreationActions",
      "Effect": "Allow",
      "Action": "iam:CreateInstanceProfile",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
          "aws:RequestTag/topology.kubernetes.io/region": "${REGION}"
        },
        "StringLike": {
          "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
        }
      }
    },
    {
      "Sid": "AllowScopedInstanceProfileTagActions",
      "Effect": "Allow",
      "Action": "iam:TagInstanceProfile",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
          "aws:ResourceTag/topology.kubernetes.io/region": "${REGION}",
          "aws:RequestTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
          "aws:RequestTag/topology.kubernetes.io/region": "${REGION}"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*",
          "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
        }
      }
    },
    {
      "Sid": "AllowScopedInstanceProfileActions",
      "Effect": "Allow",
      "Action": [
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:DeleteInstanceProfile"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
          "aws:ResourceTag/topology.kubernetes.io/region": "${REGION}"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*"
        }
      }
    },
    {
      "Sid": "AllowInstanceProfileReadActions",
      "Effect": "Allow",
      "Action": "iam:GetInstanceProfile",
      "Resource": "*"
    },
    {
      "Sid": "AllowAPIServerEndpointDiscovery",
      "Effect": "Allow",
      "Action": "eks:DescribeCluster",
      "Resource": "arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"
    }
  ]
}
EOF

KARPENTER_POLICY_ARN=$(aws iam create-policy \
  --policy-name skm-karpenter-controller-policy \
  --policy-document file:///tmp/karpenter-policy.json \
  --query 'Policy.Arn' --output text 2>/dev/null || \
  aws iam get-policy \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/skm-karpenter-controller-policy" \
    --query 'Policy.Arn' --output text)

cat > /tmp/karpenter-node-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name KarpenterNodeRole-${CLUSTER_NAME} \
  --assume-role-policy-document file:///tmp/karpenter-node-trust.json \
  --output text 2>/dev/null || echo "Karpenter Node Role already exists"

for policy in \
  arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
  arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
  arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
  arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy \
    --role-name KarpenterNodeRole-${CLUSTER_NAME} \
    --policy-arn $policy 2>/dev/null || true
done

cat > /tmp/karpenter-controller-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${KARPENTER_NS}:karpenter",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name skm-karpenter-controller-role \
  --assume-role-policy-document file:///tmp/karpenter-controller-trust.json \
  --output text 2>/dev/null || echo "Karpenter Controller Role already exists"

aws iam attach-role-policy \
  --role-name skm-karpenter-controller-role \
  --policy-arn $KARPENTER_POLICY_ARN 2>/dev/null || true

KARPENTER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/skm-karpenter-controller-role"

eksctl create iamidentitymapping \
  --cluster $CLUSTER_NAME \
  --region $REGION \
  --arn "arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --username system:node:{{EC2PrivateDNSName}} \
  --group system:bootstrappers,system:nodes 2>/dev/null || echo "mapping already exists"

echo "APP_ROLE_ARN: $APP_ROLE_ARN"
echo "KEDA_ROLE_ARN: $KEDA_ROLE_ARN"
echo "KARPENTER_ROLE_ARN: $KARPENTER_ROLE_ARN"
echo