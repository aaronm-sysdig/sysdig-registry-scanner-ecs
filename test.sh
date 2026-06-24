#!/bin/bash
#
# Scans one image by invoking the orchestrator Lambda directly (skips the
# ECR-push trigger). Useful for a quick end-to-end check after deploying.
#
# Edit the CONFIG block, then run:  ./test.sh

set -e

# ---------------------------------------------------------------------------
# CONFIG - edit these
# ---------------------------------------------------------------------------
REGION="ap-southeast-2"
ACCOUNT_ID="123456789012"
SUBNET_ID="subnet-xxxxxxxxx"
SECURITY_GROUP_ID="sg-xxxxxxxxx"
CLUSTER_NAME="Sysdig-Fargate-Test-Cluster"
IMAGE_TO_SCAN="your-repo:your-tag"             # repo:tag in your ECR
# ---------------------------------------------------------------------------

REGISTRY_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

PAYLOAD="{
  \"image_to_scan\": \"${IMAGE_TO_SCAN}\",
  \"registry_url\": \"${REGISTRY_URL}\",
  \"cluster\": \"${CLUSTER_NAME}\",
  \"task_definition\": \"Sysdig-Registry-Scanner\",
  \"subnet\": \"${SUBNET_ID}\",
  \"security_groups\": [\"${SECURITY_GROUP_ID}\"]
}"

echo "Scanning ${IMAGE_TO_SCAN} (this waits for the task to finish)..."
aws lambda invoke \
  --function-name run-registry-scan \
  --payload "$PAYLOAD" \
  --cli-binary-format raw-in-base64-out \
  --region "$REGION" \
  --cli-read-timeout 360 \
  response.json >/dev/null

echo "Response:"
cat response.json | jq .

STATUS=$(jq -r '.statusCode' response.json)
if [ "$STATUS" = "200" ]; then
  echo "PASS - scan completed successfully"
else
  echo "Check the response above and the scanner logs:"
  echo "  aws logs tail /ecs/Sysdig-Registry-Scanner --since 30m"
fi
