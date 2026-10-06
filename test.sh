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
ACCOUNT_ID=""                                  # optional: empty = the account you are logged in to; if set it must match
SUBNET_ID="subnet-xxxxxxxxx"
SECURITY_GROUP_ID="sg-xxxxxxxxx"
CLUSTER_NAME="Sysdig-Fargate-Test-Cluster"
IMAGE_TO_SCAN="your-repo:your-tag"             # repo:tag in your ECR
# ---------------------------------------------------------------------------

# Act on the account you are authenticated to, in the CONFIG region.
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
if ! CALLER=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1); then
  echo "ERROR: AWS credentials are not working: ${CALLER}"
  exit 1
fi
AUTH_ACCOUNT="${CALLER%%$'\t'*}"
AUTH_ARN="${CALLER#*$'\t'}"
if [ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != "$AUTH_ACCOUNT" ]; then
  echo "ERROR: CONFIG ACCOUNT_ID is ${ACCOUNT_ID} but you are logged in to ${AUTH_ACCOUNT} (${AUTH_ARN})."
  echo "       Log in to the right account, or clear ACCOUNT_ID to use the one you are logged in to."
  exit 1
fi
ACCOUNT_ID="$AUTH_ACCOUNT"
echo "Authenticated as ${AUTH_ARN}"

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
