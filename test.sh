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
SUBNET_ID=""                                   # empty = what the deployed ecr-push-trigger Lambda uses
SECURITY_GROUP_ID=""                           # empty = what the deployed ecr-push-trigger Lambda uses
CLUSTER_NAME=""                                # empty = what the deployed ecr-push-trigger Lambda uses
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

# ---------------------------------------------------------------------------
# Scan settings: a value set in the CONFIG block wins; an empty one is read
# from the deployed ecr-push-trigger Lambda (what deploy.sh configured). The
# source of each value is logged, and a CONFIG value that differs from what the
# deployed trigger uses is flagged.
# ---------------------------------------------------------------------------
TRIGGER_ENV=""
TRIGGER_ENV_LOADED=false
resolve_setting() {   # <variable name> <ecr-push-trigger environment key>
  local var="$1" key="$2" value="${!1}" from="CONFIG" deployed note=""
  if ! $TRIGGER_ENV_LOADED; then
    TRIGGER_ENV=$(aws lambda get-function-configuration --function-name ecr-push-trigger \
      --query 'Environment.Variables' --output json 2>/dev/null) || TRIGGER_ENV=""
    TRIGGER_ENV_LOADED=true
  fi
  deployed=$(echo "${TRIGGER_ENV:-null}" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true)
  if [ -z "$value" ]; then
    value="$deployed"; from="ecr-push-trigger Lambda"
  elif [ -n "$deployed" ] && [ "$deployed" != "$value" ]; then
    note="  WARNING: the deployed ecr-push-trigger Lambda uses ${deployed}"
  fi
  if [ -z "$value" ]; then
    echo "ERROR: ${var} is empty in CONFIG and could not be read from the ecr-push-trigger Lambda."
    echo "       Set ${var} in the CONFIG block."
    exit 1
  fi
  printf -v "$var" '%s' "$value"
  printf '  %-18s %s  (from %s)%s\n' "$var" "$value" "$from" "$note"
}

echo "Scan settings:"
resolve_setting CLUSTER_NAME ECS_CLUSTER
resolve_setting SUBNET_ID SUBNET_ID
resolve_setting SECURITY_GROUP_ID SECURITY_GROUP_ID
echo

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
