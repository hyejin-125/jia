#!/bin/bash

echo "Module 2 - CDN Function"
export AWS_ACCESS_KEY_ID=""
export AWS_SECRET_ACCESS_KEY=""
rm -rf ~/.aws
aws sts get-caller-identity | jq .Account
echo "채점준비 끝! 채점 시작!"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="skillsphone-landing-ab-${ACCOUNT_ID}"

echo "=== 2-1-A ==="

echo ${BUCKET}
aws s3api list-buckets --region us-east-1 | jq -r '[.Buckets[].Name]' | grep "skillsphone-landing-ab-"
aws s3api list-objects-v2 --bucket ${BUCKET} --region us-east-1 | jq -r '[.Contents[].Key] | "Version A HTML " + (any(.[]; . == "version-a/index.html") | tostring), "Version B HTML " + (any(.[]; . == "version-b/index.html") | tostring)'
aws s3api get-public-access-block --bucket ${BUCKET} --region us-east-1 | jq -r '.PublicAccessBlockConfiguration | "BPA All True " + (all(.[]; . == true) | tostring)'
aws s3api get-bucket-policy --bucket ${BUCKET} --region us-east-1 | jq -r '.Policy | fromjson | .Statement[0] | "Policy Principal CF " + (((.Principal.Service // "-") == "cloudfront.amazonaws.com") | tostring), "Policy Source ARN CF " + (((.Condition.StringEquals."AWS:SourceArn" // "-") | startswith("arn:aws:cloudfront::")) | tostring)'

echo "=== 2-2-A ==="

KVS=$(aws cloudfront list-key-value-stores --region us-east-1 | jq -r '.KeyValueStoreList.Items[]|select(.Name=="skillsphone-cdn-ab-config")|.ARN')
aws cloudfront-keyvaluestore list-keys --kvs-arn "$KVS" --region us-east-1 | jq -r '.Items|sort_by(.Key)|.[]|"KVS_KV \(.Key) \(.Value)"'
aws cloudfront describe-function --name skillsphone-cdn-ab-req-fn --stage LIVE --region us-east-1 | jq -r --arg k "$KVS" '.FunctionSummary | "ReqFn \(.Name) \(.Status) \(.FunctionConfig.Runtime) \((.FunctionConfig.KeyValueStoreAssociations.Items // []) | any(.KeyValueStoreARN == $k))"'
aws cloudfront describe-function --name skillsphone-cdn-ab-res-fn --stage LIVE --region us-east-1 | jq -r '.FunctionSummary | "ResFn \(.Name) \(.Status) \(.FunctionConfig.Runtime)"'

echo "=== 2-3-A ==="

CP=$(aws cloudfront list-cache-policies --region us-east-1 | jq -r '.CachePolicyList.Items[]|select(.CachePolicy.CachePolicyConfig.Name=="skillsphone-cdn-ab-cache-policy")|.CachePolicy.Id')
DID=$(aws cloudfront list-distributions --region us-east-1 | jq -r '.DistributionList.Items[]|select(.Comment=="skillsphone-cdn-ab-distribution")|.Id')

aws cloudfront get-cache-policy --id "$CP" --region us-east-1 | jq -r '.CachePolicy.CachePolicyConfig |
  "Cache Config \(.Name) \(.ParametersInCacheKeyAndForwardedToOrigin.CookiesConfig.CookieBehavior) \((.ParametersInCacheKeyAndForwardedToOrigin.CookiesConfig.Cookies.Items // []) | sort | join(","))",
  "Cache TTL \(.MinTTL) \(.DefaultTTL) \(.MaxTTL)"'

aws cloudfront get-distribution-config --id "$DID" --region us-east-1 | jq -r --arg c "$CP" \
  '.DistributionConfig.DefaultCacheBehavior as $b | .DistributionConfig.Origins.Items[0] as $o |
   "ViewerProtocol \($b.ViewerProtocolPolicy)",
   "\((($o.OriginAccessControlId // "") | length) > 0) \($b.CachePolicyId == $c)",
   "\(((($b.FunctionAssociations.Items // [])[] | select(.EventType=="viewer-request") | .FunctionARN) // "-") | sub(".*function/"; "")) \(((($b.FunctionAssociations.Items // [])[] | select(.EventType=="viewer-response") | .FunctionARN) // "-") | sub(".*function/"; ""))"'

echo "=== 2-4-A ==="

D=$(aws cloudfront list-distributions --region us-east-1 | jq -r '.DistributionList.Items[]|select(.Comment=="skillsphone-cdn-ab-distribution")|.DomainName')
RH=$(curl -s -i --max-time 10 "http://$D/")

B= S=
for v in a b; do
  R=$(curl -sim10 -b x-sp-ab=$v "https://$D/?_$RANDOM")
  grep -q "version_$v" <<<"$R" && B+=" true" || B+=" false"
  grep -qi "^set-cookie:" <<<"$R" && S+=" false" || S+=" true"
done
echo "cookie_a_b_body$B"
echo "cookie_a_b_no_setcookie$S"

echo "$(echo "$RH" | head -1 | grep -qE '30[12]' && echo true || echo false) $(echo "$RH" | grep -i '^location:' | grep -q 'https://' && echo true || echo false)"

echo "=== 2-5-A ==="

D=$(aws cloudfront list-distributions --region us-east-1 | jq -r '.DistributionList.Items[]|select(.Comment=="skillsphone-cdn-ab-distribution")|.DomainName')

R1=$(curl -s -i --max-time 10 "https://$D/?_=$(date +%s%N)")
V=$(echo "$R1" | grep -i '^set-cookie:' | sed -n 's|.*x-sp-ab=\([ab]\).*|\1|p')
SC=$(echo "$R1" | grep -i '^set-cookie:')

echo "first_visit_assigned $V"
echo "first_visit_body_match $(echo "$R1" | grep -q "version_$V" && echo true || echo false)"
echo "first_visit_setcookie_maxage $(echo "$SC" | grep -q 'Max-Age=86400' && echo true || echo false)"
echo "first_visit_setcookie_path $(echo "$SC" | grep -q 'Path=/' && echo true || echo false)"

R2=$(curl -s -i --max-time 10 -H "Cookie: x-sp-ab=$V" "https://$D/?_=$(date +%s%N)")
echo "second_visit_body_match $(echo "$R2" | grep -q "version_$V" && echo true || echo false)"
echo "second_visit_no_setcookie $([ $(echo "$R2" | grep -ic '^set-cookie:') -eq 0 ] && echo true || echo false)"

echo "=== 2-6-A ==="

KVS=$(aws cloudfront list-key-value-stores --region us-east-1 | jq -r '.KeyValueStoreList.Items[]|select(.Name=="skillsphone-cdn-ab-config")|.ARN')
ORIG=$(aws cloudfront-keyvaluestore get-key --kvs-arn "$KVS" --key weight --region us-east-1 | jq -r .Value)
ETAG=$(aws cloudfront-keyvaluestore describe-key-value-store --kvs-arn "$KVS" --region us-east-1 | jq -r .ETag)
FETAG=$(aws cloudfront describe-function --name skillsphone-cdn-ab-req-fn --stage LIVE --region us-east-1 --query ETag --output text)

echo '{"version":"1.0","context":{"eventType":"viewer-request"},"viewer":{"ip":"1.2.3.4"},"request":{"method":"GET","uri":"/","querystring":{},"headers":{},"cookies":{}}}' > /tmp/e.json

for w in 1.0 0.0; do
  ETAG=$(aws cloudfront-keyvaluestore put-key --kvs-arn "$KVS" --if-match "$ETAG" --key weight --value "$w" --region us-east-1 | jq -r .ETag)
  sleep 30
  URI=$(aws cloudfront test-function --name skillsphone-cdn-ab-req-fn --if-match "$FETAG" --stage LIVE --event-object fileb:///tmp/e.json --region us-east-1 | jq -r '.TestResult.FunctionOutput|fromjson|.request.uri')
  echo "weight_${w%.*}_uri $URI"
done

aws cloudfront-keyvaluestore put-key --kvs-arn "$KVS" --if-match "$ETAG" --key weight --value "$ORIG" --region us-east-1 > /dev/null
echo "weight_restored $(aws cloudfront-keyvaluestore get-key --kvs-arn "$KVS" --key weight --region us-east-1 | jq -r .Value)"