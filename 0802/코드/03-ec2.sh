#!/bin/bash
set -x

REGION="ap-northeast-1"
CLIENT_VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=skills-lattice-client-vpc" --query "Vpcs[0].VpcId" --output text)
SERVICE_VPC_ID=$(aws ec2 describe-vpcs --region $REGION --filters "Name=tag:Name,Values=skills-lattice-service-vpc" --query "Vpcs[0].VpcId" --output text)
CLIENT_SUB_ID=$(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$CLIENT_VPC_ID" "Name=tag:Name,Values=skills-lattice-client-pub-1" --query "Subnets[0].SubnetId" --output text)
SERVICE_SUB_ID=$(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$SERVICE_VPC_ID" "Name=tag:Name,Values=skills-lattice-service-priv-1" --query "Subnets[0].SubnetId" --output text)
AMI_ID=$(aws ssm get-parameters --region $REGION --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query "Parameters[0].Value" --output text)

CLIENT_EC2_SG_ID=$(aws ec2 create-security-group --region $REGION \
    --group-name "skills-lattice-client-ec2-sg" \
    --description "Client EC2 Security Group" \
    --vpc-id $CLIENT_VPC_ID \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress --region $REGION \
    --group-id $CLIENT_EC2_SG_ID \
    --protocol tcp --port 80 --cidr 0.0.0.0/0

LATTICE_PL_ID=$(aws ec2 describe-managed-prefix-lists --region $REGION \
    --filters "Name=prefix-list-name,Values=com.amazonaws.${REGION}.vpc-lattice" \
    --query "PrefixLists[0].PrefixListId" --output text)

SERVICE_EC2_SG_ID=$(aws ec2 create-security-group --region $REGION \
    --group-name "skills-lattice-service-ec2-sg" \
    --description "Service EC2 Security Group" \
    --vpc-id $SERVICE_VPC_ID \
    --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress --region $REGION \
    --group-id $SERVICE_EC2_SG_ID \
    --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,PrefixListIds=[{PrefixListId=$LATTICE_PL_ID}]"

read -r -d '' SERVICE_USER_DATA << 'EOF'
#!/bin/bash
yum update -y
yum install python3-pip -y
cat << 'APP_EOF' > /home/ec2-user/service_app.py
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

class ServiceHandler(BaseHTTPRequestHandler):
    def _send_json(self, status_code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._send_json(200, {"status": "ok", "app": "service"})
            return

        if parsed.path == "/v1/orders":
            order_id = parse_qs(parsed.query).get("id", ["1001"])[0]
            self._send_json(200, {"order_id": order_id, "via": "vpc-lattice"})
            return

        self._send_json(404, {"error": "not found"})

if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 8080), ServiceHandler)
    server.serve_forever()
APP_EOF
chown ec2-user:ec2-user /home/ec2-user/service_app.py
cd /home/ec2-user/
sudo -u ec2-user nohup python3 service_app.py > /home/ec2-user/app.log 2>&1 &
EOF

SERVICE_EC2_ID=$(aws ec2 run-instances --region $REGION \
    --image-id $AMI_ID \
    --instance-type t3.micro \
    --subnet-id $SERVICE_SUB_ID \
    --security-group-ids $SERVICE_EC2_SG_ID \
    --user-data "$SERVICE_USER_DATA" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=skills-lattice-service-ec2}]' \
    --query "Instances[0].InstanceId" --output text)

echo "Waiting for Service EC2 ($SERVICE_EC2_ID) to be in 'running' state..."
aws ec2 wait instance-running --region $REGION --instance-ids $SERVICE_EC2_ID

TG_ID=$(aws vpc-lattice list-target-groups --region $REGION --query "items[?name=='skills-lattice-order-tg'].id" --output text)

SERVICE_ID=$(aws vpc-lattice list-services --region $REGION --query "items[?name=='skills-lattice-order-service'].id" --output text)

echo "Waiting for Lattice Domain Name to be provisioned..."
while true; do
    LATTICE_DOMAIN=$(aws vpc-lattice get-service --region $REGION --service-identifier $SERVICE_ID --query "dnsEntry.domainName" --output text 2>/dev/null)
    if [ -n "$LATTICE_DOMAIN" ] && [ "$LATTICE_DOMAIN" != "None" ]; then
        break
    fi
    sleep 5
done
echo "Lattice Domain successfully retrieved: $LATTICE_DOMAIN"

read -r -d '' CLIENT_USER_DATA << EOF
#!/bin/bash
yum update -y
yum install python3-pip -y

cat << 'APP_EOF' > /home/ec2-user/client_app.py
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen

SERVICE_URL = os.environ.get("SERVICE_URL", "").rstrip("/")

class ClientHandler(BaseHTTPRequestHandler):
    def _send_json(self, status_code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._send_json(200, {"status": "ok", "app": "client"})
            return

        if parsed.path == "/v1/client/orders":
            order_id = parse_qs(parsed.query).get("id", ["1001"])[0]
            if not SERVICE_URL:
                self._send_json(500, {"error": "SERVICE_URL is not configured"})
                return
            request = Request(f"{SERVICE_URL}/v1/orders?id={order_id}")
            try:
                with urlopen(request, timeout=5) as response:
                    service_payload = json.loads(response.read().decode("utf-8"))
                self._send_json(200, {"client": "ok", "service": service_payload})
            except Exception as e:
                self._send_json(502, {"error": str(e)})
            return

        self._send_json(404, {"error": "not found"})

if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 80), ClientHandler)
    server.serve_forever()
APP_EOF

echo "export SERVICE_URL=http://$LATTICE_DOMAIN" > /home/ec2-user/.env
cat << 'RUN_EOF' > /home/ec2-user/run.sh
#!/bin/bash
source /home/ec2-user/.env
cd /home/ec2-user/
nohup python3 client_app.py > /home/ec2-user/app.log 2>&1 &
RUN_EOF

chmod +x /home/ec2-user/run.sh
chown ec2-user:ec2-user /home/ec2-user/client_app.py /home/ec2-user/.env /home/ec2-user/run.sh

sudo -E /home/ec2-user/run.sh
EOF

CLIENT_EC2_ID=$(aws ec2 run-instances --region $REGION \
    --image-id $AMI_ID \
    --instance-type t3.micro \
    --subnet-id $CLIENT_SUB_ID \
    --security-group-ids $CLIENT_EC2_SG_ID \
    --associate-public-ip-address \
    --user-data "$CLIENT_USER_DATA" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=skills-lattice-client-ec2}]' \
    --query "Instances[0].InstanceId" --output text)

aws vpc-lattice register-targets --region $REGION \
    --target-group-identifier $TG_ID \
    --targets id=$SERVICE_EC2_ID,port=8080
echo