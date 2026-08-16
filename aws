## Dockerfile
```bash
FROM ubuntu:24.04
RUN apt-get update && apt-get upgrade -y && \
  apt-get install -y --no-install-recommends curl ca-certificates && \
  rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --chmod=755 ./book ./book
ENV AWS_REGION="ap-northeast-2"
ENV TABLE_NAME="wskorea26-data-table"
EXPOSE 8080
CMD ["./book"]
EOF
```

```bash
#!/bin/bash
sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/g" /etc/ssh/sshd_config
echo "ec2-user:1234" | chpasswd
systemctl restart sshd
```

```bash
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
```
```bash
CLUSTER_NAME="<클러스터 이름>"
eksctl utils write-kubeconfig --name $CLUSTER_NAME
eksctl utils associate-iam-oidc-provider --approve --cluster $CLUSTER_NAME
```

<br>

## config.yml
https://github.com/rebuy-de/aws-nuke/releases
```bash
regions:
  - global
  - us-east-1      # 미국 동부 (버지니아 북부)
  # - us-east-2      # 미국 동부 (오하이오)
  # - us-west-1      # 미국 서부 (캘리포니아 북부)
  # - us-west-2      # 미국 서부 (오레곤)
  # - ca-central-1   # 캐나다 (중부)
  # - ca-west-1      # 캐나다 (서부)
  # - sa-east-1      # 남미 (상파울루)
  # - ap-northeast-1 # 아시아 태평양 (도쿄)
  # - ap-northeast-2 # 아시아 태평양 (서울)
  # - ap-northeast-3 # 아시아 태평양 (오사카)
  # - ap-south-1     # 아시아 태평양 (뭄바이)
  # - ap-south-2     # 아시아 태평양 (하이데라바드)
  # - ap-southeast-1 # 아시아 태평양 (싱가포르)
  # - ap-southeast-2 # 아시아 태평양 (시드니)
  # - ap-southeast-3 # 아시아 태평양 (자카르타)
  # - ap-southeast-4 # 아시아 태평양 (멜버른)
  # - ap-east-1      # 아시아 태평양 (홍콩)
  # - eu-west-1      # 유럽 (아일랜드)
  # - eu-west-2      # 유럽 (런던)
  # - eu-west-3      # 유럽 (파리)
  # - eu-central-1   # 유럽 (프랑크푸르트)
  # - eu-central-2   # 유럽 (취리히)
  # - eu-south-1     # 유럽 (밀라노)
  # - eu-south-2     # 유럽 (스페인)
  # - eu-north-1     # 유럽 (스톡홀름)
  # - me-central-1   # 중동 (UAE)
  # - me-south-1     # 중동 (바레인)
  # - af-south-1     # 아프리카 (케이프타운)

account-blocklist:
  - "999999999999"

resource-types:
  excludes:
  - IAMUserPolicyAttachment
  - IAMLoginProfile

accounts:
  "사용자 아이디":
    filters:
      IAMUser:
        - "nuke"
        - "sysop"
      IAMUserPolicyAttachment:
        - type: "glob"
          value: "nuke -> *"
        - type: "glob"
          value: "sysop -> *"
      IAMUserAccessKey:
        - type: "glob"
          value: "nuke -> *"
        - type: "glob"
          value: "sysop -> *"
```
```bash
aws configure --profile <사용자 별칭>
```
```bash
./aws-nuke-v2.25.0-windows-amd64.exe -c ./config.yml --no-dry-run --profile <사용자 별칭>
```
