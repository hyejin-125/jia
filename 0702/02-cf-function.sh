#!/bin/bash
set -x

KVS_ARN=$(aws cloudfront create-key-value-store \
    --name skillsphone-cdn-ab-config \
    --comment "KVS for AB testing" \
    --query 'KeyValueStore.ARN' \
    --output text 2>/dev/null || \
    aws cloudfront describe-key-value-store \
    --name skillsphone-cdn-ab-config \
    --query 'KeyValueStore.ARN' \
    --output text)

while true; do
  KVS_STATUS=$(aws cloudfront describe-key-value-store \
    --name skillsphone-cdn-ab-config \
    --query 'KeyValueStore.Status' \
    --output text 2>/dev/null)

  [ "$KVS_STATUS" = "READY" ] && break

  echo "Waiting for KVS... status=$KVS_STATUS"
  sleep 2
done

KVS_ETAG=$(aws cloudfront-keyvaluestore describe-key-value-store --kvs-arn $KVS_ARN --query 'ETag' --output text)

KVS_ETAG=$(aws cloudfront-keyvaluestore put-key \
    --kvs-arn $KVS_ARN \
    --if-match $KVS_ETAG \
    --key "weight" \
    --value "0.3" \
    --query 'ETag' \
    --output text)

KVS_ETAG=$(aws cloudfront-keyvaluestore put-key \
    --kvs-arn $KVS_ARN \
    --if-match $KVS_ETAG \
    --key "version_a" \
    --value "/version-a/index.html" \
    --query 'ETag' \
    --output text)

aws cloudfront-keyvaluestore put-key \
    --kvs-arn $KVS_ARN \
    --if-match $KVS_ETAG \
    --key "version_b" \
    --value "/version-b/index.html" >/dev/null

# 4. Request Function 생성 및 게시
cat << 'EOF' > req_fn.js
import cf from 'cloudfront';

const kvsHandle = cf.kvs(); 

async function handler(event) {
    const request = event.request;
    const cookies = request.cookies;
    let assignedVersion = ''; 
    let finalPath = '';

    if (cookies && cookies['x-sp-ab'] && cookies['x-sp-ab'].value) {
        assignedVersion = cookies['x-sp-ab'].value;
    } else {
        try {
            const weightRaw = await kvsHandle.get('weight');
            let weight = parseFloat(weightRaw.trim());
            if (isNaN(weight)) { weight = 0.3; }
            if (Math.random() < weight) { assignedVersion = 'b'; } 
            else { assignedVersion = 'a'; }
        } catch (err) { assignedVersion = 'a'; }
        request.headers['x-sp-ab-assigned'] = { value: assignedVersion };
    }

    try {
        if (assignedVersion === 'b') { finalPath = await kvsHandle.get('version_b'); } 
        else { finalPath = await kvsHandle.get('version_a'); }
        finalPath = finalPath.trim();
    } catch (e) {
        finalPath = '/version-a/index.html';
    }

    request.uri = finalPath;
    return request;
}
EOF

cat << EOF > req-func-config.json
{
    "Comment": "Viewer Request for AB Testing",
    "Runtime": "cloudfront-js-2.0",
    "KeyValueStoreAssociations": {
        "Quantity": 1,
        "Items": [{"KeyValueStoreARN": "$KVS_ARN"}]
    }
}
EOF

aws cloudfront create-function --name skillsphone-cdn-ab-req-fn --function-config file://req-func-config.json --function-code fileb://req_fn.js >/dev/null 2>&1
REQ_ETAG=$(aws cloudfront describe-function --name skillsphone-cdn-ab-req-fn --query 'ETag' --output text)
aws cloudfront publish-function --name skillsphone-cdn-ab-req-fn --if-match $REQ_ETAG >/dev/null
REQ_FN_ARN=$(aws cloudfront describe-function --name skillsphone-cdn-ab-req-fn --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text)

# 5. Response Function 생성 및 게시
cat << 'EOF' > res_fn.js
function handler(event) {
    const request = event.request;
    const response = event.response;
    
    if (request.headers['x-sp-ab-assigned'] && request.headers['x-sp-ab-assigned'].value) {
        const assignedVersion = request.headers['x-sp-ab-assigned'].value;
        response.cookies['x-sp-ab'] = {
            value: assignedVersion,
            attributes: "Path=/; Max-Age=86400"
        };
    }
    return response;
}
EOF

cat << EOF > res-func-config.json
{
    "Comment": "Viewer Response for AB Testing",
    "Runtime": "cloudfront-js-2.0"
}
EOF

aws cloudfront create-function --name skillsphone-cdn-ab-res-fn --function-config file://res-func-config.json --function-code fileb://res_fn.js >/dev/null 2>&1
RES_ETAG=$(aws cloudfront describe-function --name skillsphone-cdn-ab-res-fn --query 'ETag' --output text)
aws cloudfront publish-function --name skillsphone-cdn-ab-res-fn --if-match $RES_ETAG >/dev/null
RES_FN_ARN=$(aws cloudfront describe-function --name skillsphone-cdn-ab-res-fn --query 'FunctionSummary.FunctionMetadata.FunctionARN' --output text)
