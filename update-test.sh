#!/bin/bash
#
# Checks quay.io for a newer Sysdig registry-scanner image than the one
# deployed, tests it with one real scan, and offers to deploy it.
#
# The test never touches the live scanner: it registers a copy of the live task
# definition under a separate family (Sysdig-Registry-Scanner-Test) with only
# the image changed, and scans one image with it. The live family is only
# updated if the test passes and you answer yes: the exact definition that was
# tested is then registered as a new revision of the live family (deploy.sh is
# not run, so nothing else in your account is touched).
#
# Usage:
#   ./update-test.sh --image repo:tag [--check] [--version TAG] [--skip-tls true|false]
#
# Options:
#   --image repo:tag   an image in your ECR to scan as the test (required unless
#                      TEST_IMAGE is set below)
#   --check            only report whether a newer version exists, do not test
#   --version TAG      test this tag (e.g. job-0.12.3) instead of the newest
#   --skip-tls VALUE   also set REGISTRYSCANNER_SECURE_SKIPTLS to true or false in
#                      the tested definition (and in the live one if you deploy)
#
# Needs: aws, jq, curl.

set -e

# ---------------------------------------------------------------------------
# CONFIG - edit these for your environment
# ---------------------------------------------------------------------------
REGION="ap-southeast-2"
ACCOUNT_ID=""                                  # optional: empty = the account you are logged in to; if set it must match
CLUSTER_NAME=""                                # empty = read from the deployed ecr-push-trigger Lambda
SUBNET_ID=""                                   # empty = read from the deployed ecr-push-trigger Lambda
SECURITY_GROUP_ID=""                           # empty = read from the deployed ecr-push-trigger Lambda
TEST_IMAGE=""                                  # repo:tag in your ECR to scan as the test
# ---------------------------------------------------------------------------

LIVE_FAMILY="Sysdig-Registry-Scanner"
TEST_FAMILY="Sysdig-Registry-Scanner-Test"
QUAY_API="https://quay.io/api/v1/repository/sysdig/registry-scanner/tag/?limit=100&onlyActiveTags=true"

CHECK_ONLY=false
WANT_VERSION=""
SKIP_TLS=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --image)   TEST_IMAGE="$2";   shift 2 ;;
    --check)   CHECK_ONLY=true;   shift   ;;
    --version) WANT_VERSION="$2"; shift 2 ;;
    --skip-tls) SKIP_TLS="$2";    shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -n "$SKIP_TLS" ] && [ "$SKIP_TLS" != "true" ] && [ "$SKIP_TLS" != "false" ]; then
  echo "ERROR: --skip-tls must be true or false."
  exit 1
fi

cd "$(dirname "$0")"

for tool in aws jq curl; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required but not installed."; exit 1; }
done

# ---------------------------------------------------------------------------
# Act on the account you are authenticated to, in the CONFIG region.
# ---------------------------------------------------------------------------
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
echo "Authenticated as ${AUTH_ARN} (${REGION})"
echo

# ---------------------------------------------------------------------------
echo "Step 1: what is deployed"
# ---------------------------------------------------------------------------
if ! LIVE_JSON=$(aws ecs describe-task-definition --task-definition "$LIVE_FAMILY" \
      --query taskDefinition --output json 2>/dev/null); then
  echo "  ERROR: task definition '${LIVE_FAMILY}' not found. Run ./deploy.sh first."
  exit 1
fi
LIVE_REVISION=$(echo "$LIVE_JSON" | jq -r '.revision')
CURRENT_IMAGE=$(echo "$LIVE_JSON" | jq -r '.containerDefinitions[0].image')
CURRENT_TAG="${CURRENT_IMAGE##*:}"
IMAGE_REPO="${CURRENT_IMAGE%:*}"
echo "  ${LIVE_FAMILY}:${LIVE_REVISION} runs ${CURRENT_IMAGE}"
echo

# ---------------------------------------------------------------------------
echo "Step 2: newest version on quay.io"
# ---------------------------------------------------------------------------
if ! TAGS_JSON=$(curl -sf -m 30 "$QUAY_API"); then
  echo "  ERROR: could not reach quay.io to list tags."
  exit 1
fi

# Plain job-X.Y.Z tags only. Stay on the -fips line if that is what is deployed.
if [[ "$CURRENT_TAG" == *-fips ]]; then PATTERN='^job-[0-9]+\.[0-9]+\.[0-9]+-fips$'
else PATTERN='^job-[0-9]+\.[0-9]+\.[0-9]+$'; fi
CANDIDATES=$(echo "$TAGS_JSON" | jq -r --arg p "$PATTERN" '.tags[].name | select(test($p))')
if [ -z "$CANDIDATES" ]; then
  echo "  ERROR: no tags matching ${PATTERN} found on quay.io."
  exit 1
fi

if [ -n "$WANT_VERSION" ]; then
  if ! echo "$CANDIDATES" | grep -qx "$WANT_VERSION"; then
    echo "  ERROR: '${WANT_VERSION}' is not a known tag. Available: $(echo "$CANDIDATES" | sort -V | tail -5 | tr '\n' ' ')"
    exit 1
  fi
  NEW_TAG="$WANT_VERSION"
else
  NEW_TAG=$(echo "$CANDIDATES" | sort -V | tail -1)
fi
NEW_DATE=$(echo "$TAGS_JSON" | jq -r --arg t "$NEW_TAG" '.tags[] | select(.name == $t) | .last_modified')
NEW_DIGEST=$(echo "$TAGS_JSON" | jq -r --arg t "$NEW_TAG" '.tags[] | select(.name == $t) | .manifest_digest')
echo "  newest: ${NEW_TAG} (${NEW_DATE})"
echo "  digest: ${NEW_DIGEST}"

if [ -z "$WANT_VERSION" ]; then
  if [ "$NEW_TAG" = "$CURRENT_TAG" ] || \
     [ "$(printf '%s\n%s\n' "$CURRENT_TAG" "$NEW_TAG" | sort -V | tail -1)" = "$CURRENT_TAG" ]; then
    echo "  deployed ${CURRENT_TAG} is already the newest. Nothing to do."
    exit 0
  fi
  echo "  update available: ${CURRENT_TAG} -> ${NEW_TAG}"
fi
echo

if $CHECK_ONLY; then
  echo "(--check: not testing)"
  exit 0
fi

if [ -z "$TEST_IMAGE" ]; then
  echo "ERROR: no test image. Pass --image repo:tag (an image in your ECR) or set TEST_IMAGE."
  exit 1
fi

# ---------------------------------------------------------------------------
echo "Step 3: scan settings"
# ---------------------------------------------------------------------------
# A value set in the CONFIG block wins; an empty one is read from the deployed
# ecr-push-trigger Lambda (what deploy.sh configured). The source of each value
# is logged, and a CONFIG value that differs from the deployed trigger is flagged.
TRIGGER_ERR=""
if ! TRIGGER_ENV=$(aws lambda get-function-configuration --function-name ecr-push-trigger \
      --query 'Environment.Variables' --output json 2>&1); then
  TRIGGER_ERR=$(echo "$TRIGGER_ENV" | tr '\n' ' ' | cut -c1-200)
  TRIGGER_ENV=""
fi
resolve_setting() {   # <variable name> <ecr-push-trigger environment key> [default the trigger falls back to]
  local var="$1" key="$2" value="${!1}" from="CONFIG" deployed="" note=""
  if [ -n "$TRIGGER_ENV" ]; then
    deployed=$(echo "$TRIGGER_ENV" | jq -r --arg k "$key" '.[$k] // empty')
    deployed="${deployed:-$3}"
  fi
  if [ -z "$value" ]; then
    value="$deployed"; from="ecr-push-trigger Lambda"
  elif [ -z "$TRIGGER_ENV" ]; then
    note="  (not compared: could not read the ecr-push-trigger Lambda: ${TRIGGER_ERR})"
  elif [ -n "$deployed" ] && [ "$deployed" != "$value" ]; then
    note="  WARNING: the deployed ecr-push-trigger Lambda uses ${deployed}"
  fi
  if [ -z "$value" ]; then
    echo "ERROR: ${var} is empty in CONFIG and could not be read from the ecr-push-trigger Lambda${TRIGGER_ERR:+: ${TRIGGER_ERR}}."
    echo "       Set ${var} in the CONFIG block."
    exit 1
  fi
  printf -v "$var" '%s' "$value"
  printf '  %-18s %s  (from %s)%s\n' "$var" "$value" "$from" "$note"
}
resolve_setting CLUSTER_NAME ECS_CLUSTER Sysdig-Fargate-Test-Cluster
resolve_setting SUBNET_ID SUBNET_ID
resolve_setting SECURITY_GROUP_ID SECURITY_GROUP_ID
echo "  test image         ${TEST_IMAGE}"
echo

# ---------------------------------------------------------------------------
echo "Step 4: register a test task definition (${TEST_FAMILY}) with ${NEW_TAG}"
# ---------------------------------------------------------------------------
# Copy the live definition, drop the fields ECS adds, change only family+image.
# REGISTER_JSON is the definition under test; if you deploy, this same JSON is
# registered as the new live revision, so what ships is exactly what was tested.
REGISTER_JSON=$(echo "$LIVE_JSON" | jq --arg img "${IMAGE_REPO}:${NEW_TAG}" --arg tls "$SKIP_TLS" '
  {taskRoleArn, executionRoleArn, networkMode, containerDefinitions,
   volumes, requiresCompatibilities, cpu, memory, runtimePlatform, ephemeralStorage}
  | .containerDefinitions[0].image = $img
  | if $tls != "" then
      .containerDefinitions[0].environment =
        ((.containerDefinitions[0].environment // [])
         | map(select(.name != "REGISTRYSCANNER_SECURE_SKIPTLS"))
         + [{name: "REGISTRYSCANNER_SECURE_SKIPTLS", value: $tls}])
    else . end
  | with_entries(select(.value != null))')
[ -n "$SKIP_TLS" ] && echo "  REGISTRYSCANNER_SECURE_SKIPTLS=${SKIP_TLS} in the tested definition"
TEST_TD_FILE=$(mktemp /tmp/update-test-XXXXXX)
echo "$REGISTER_JSON" | jq --arg fam "$TEST_FAMILY" '. + {family: $fam}' > "$TEST_TD_FILE"
TEST_TD_ARN=$(aws ecs register-task-definition --cli-input-json "file://${TEST_TD_FILE}" \
  --query 'taskDefinition.taskDefinitionArn' --output text)
rm -f "$TEST_TD_FILE"
echo "  ${TEST_TD_ARN}"
# Always remove the test revision, pass or fail.
trap 'aws ecs deregister-task-definition --task-definition "$TEST_TD_ARN" >/dev/null 2>&1 || true' EXIT
echo

# ---------------------------------------------------------------------------
echo "Step 5: scan ${TEST_IMAGE} with ${NEW_TAG} (waits for the task to finish)"
# ---------------------------------------------------------------------------
PAYLOAD=$(jq -n --arg img "$TEST_IMAGE" --arg reg "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" \
  --arg cl "$CLUSTER_NAME" --arg td "$TEST_FAMILY" --arg sn "$SUBNET_ID" --arg sg "$SECURITY_GROUP_ID" \
  '{image_to_scan: $img, registry_url: $reg, cluster: $cl, task_definition: $td,
    subnet: $sn, security_groups: [$sg]}')
RESPONSE_FILE=$(mktemp /tmp/update-test-resp-XXXXXX)
aws lambda invoke --function-name run-registry-scan --payload "$PAYLOAD" \
  --cli-binary-format raw-in-base64-out --cli-read-timeout 1000 \
  "$RESPONSE_FILE" >/dev/null 2>"${RESPONSE_FILE}.err" || true

STATUS=$(jq -r '.statusCode // "none"' "$RESPONSE_FILE" 2>/dev/null || echo "none")
MSG=$(jq -r 'if .body then (.body | fromjson | (.message // .error // "unknown"))
             else (.errorMessage // "no response from Lambda") end' "$RESPONSE_FILE" 2>/dev/null || true)
TASK_ID=$(jq -r 'if .body then (.body | fromjson | .task_id // empty) else empty end' "$RESPONSE_FILE" 2>/dev/null || true)
CLI_ERR=$(tr '\n' ' ' < "${RESPONSE_FILE}.err" 2>/dev/null | cut -c1-300)
rm -f "$RESPONSE_FILE" "${RESPONSE_FILE}.err"

echo "  status ${STATUS}: ${MSG:-no response}${CLI_ERR:+ (aws cli: $CLI_ERR)}"
[ -n "$TASK_ID" ] && echo "  task ${TASK_ID}"
echo

if [ "$STATUS" != "200" ]; then
  echo "FAIL - ${NEW_TAG} did not scan ${TEST_IMAGE}. The live scanner is unchanged (${CURRENT_TAG})."
  [ -n "$TASK_ID" ] && echo "  aws logs tail /ecs/Sysdig-Registry-Scanner --since 30m --region ${REGION} | grep ${TASK_ID}"
  exit 1
fi
echo "PASS - ${NEW_TAG} scanned ${TEST_IMAGE} successfully."
echo

# ---------------------------------------------------------------------------
echo "Step 6: deploy"
# ---------------------------------------------------------------------------
if [ ! -t 0 ]; then
  echo "  Not interactive, so not deployed. Re-run in a terminal to be asked."
  exit 0
fi
read -r -p "  Deploy ${NEW_TAG} (replaces ${CURRENT_TAG}) now? [y/N] " ANSWER
if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
  echo "  Not deployed. The live scanner is unchanged (${CURRENT_TAG})."
  exit 0
fi

# Register exactly the tested definition as a new revision of the live family.
LIVE_TD_FILE=$(mktemp /tmp/update-test-XXXXXX)
echo "$REGISTER_JSON" | jq --arg fam "$LIVE_FAMILY" '. + {family: $fam}' > "$LIVE_TD_FILE"
NEW_REVISION=$(aws ecs register-task-definition --cli-input-json "file://${LIVE_TD_FILE}" \
  --query 'taskDefinition.revision' --output text)
rm -f "$LIVE_TD_FILE"
echo "  registered ${LIVE_FAMILY}:${NEW_REVISION} running ${NEW_TAG}"
echo "  The scanner Lambdas use the latest revision, so new scans use it now."

# Keep the repo template in step so the next deploy.sh does not revert it.
TEMPLATE="ecs/task-definition-template.json"
sed "s|${IMAGE_REPO}:${CURRENT_TAG}|${IMAGE_REPO}:${NEW_TAG}|" "$TEMPLATE" > "${TEMPLATE}.new"
if cmp -s "$TEMPLATE" "${TEMPLATE}.new"; then
  rm -f "${TEMPLATE}.new"
  echo "  WARNING: ${TEMPLATE} does not reference ${IMAGE_REPO}:${CURRENT_TAG}."
  echo "           Update its image to ${NEW_TAG} by hand, or the next ./deploy.sh will revert it."
else
  mv "${TEMPLATE}.new" "$TEMPLATE"
  echo "  ${TEMPLATE} now uses ${NEW_TAG} (review and commit it)"
fi
if [ -n "$SKIP_TLS" ]; then
  echo "  NOTE: you deployed SECURE_SKIPTLS=${SKIP_TLS}. Set SECURE_SKIPTLS=\"${SKIP_TLS}\" in the CONFIG block of"
  echo "        deploy.sh too, or the next ./deploy.sh will put it back to its CONFIG value."
fi
