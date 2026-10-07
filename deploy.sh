#!/bin/bash
#
# Deploys the Sysdig registry scanner solution:
#   - IAM roles for the Lambdas and the Fargate task
#   - an ECS cluster (logical only - Fargate has no nodes)
#   - the scanner task definition
#   - the orchestrator Lambda (run-registry-scan)
#   - the trigger Lambda (ecr-push-trigger)
#   - an EventBridge rule that runs a scan on every ECR push
#
# Edit the CONFIG block below, then run:  ./deploy.sh
# Re-running is safe; it updates anything that already exists.

set -e

# ---------------------------------------------------------------------------
# CONFIG - edit these for your environment
# ---------------------------------------------------------------------------
REGION="ap-southeast-2"
ACCOUNT_ID=""                                  # optional: empty = the account you are logged in to; if set it must match
SUBNET_ID="subnet-xxxxxxxxx"                   # must have outbound internet (public or NAT)
SECURITY_GROUP_ID="sg-xxxxxxxxx"               # must allow outbound HTTPS (443)
SYSDIG_API_URL="https://app.au1.sysdig.com"
SECRET_NAME="SECURE_API_TOKEN"                 # Secrets Manager secret holding the Sysdig API token
CLUSTER_NAME="Sysdig-Fargate-Test-Cluster"
SECURE_SKIPTLS="false"                         # "true" disables certificate checks to Sysdig; only for a TLS-intercepting proxy
# ---------------------------------------------------------------------------

for tool in aws jq zip; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required but not installed."; exit 1; }
done

if ! [[ "$SUBNET_ID" =~ ^subnet-[0-9a-f]+$ ]] || ! [[ "$SECURITY_GROUP_ID" =~ ^sg-[0-9a-f]+$ ]]; then
  echo "ERROR: set SUBNET_ID and SECURITY_GROUP_ID in the CONFIG block of deploy.sh (still placeholders or invalid)."
  exit 1
fi
if [ "$SECURE_SKIPTLS" != "true" ] && [ "$SECURE_SKIPTLS" != "false" ]; then
  echo "ERROR: SECURE_SKIPTLS must be \"true\" or \"false\"."
  exit 1
fi

# ---------------------------------------------------------------------------
# Account/region guard: act on the account you are authenticated to, and make
# the CONFIG region the one every aws call uses.
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
echo "Authenticated as ${AUTH_ARN}"

REGISTRY_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
LAMBDA_ROLE="lambda-registry-scanner-role"
# A role used only by this solution. Earlier versions used the shared default
# name ecsTaskExecutionRole; see the README ("Migrating from ecsTaskExecutionRole").
TASK_ROLE="sysdig-registry-scanner-task-role"
cd "$(dirname "$0")"

# Private scratch directory (no fixed /tmp paths another user could pre-create).
WORKDIR=$(mktemp -d)
trap 'rm -f "$WORKDIR/task-definition.json" "$WORKDIR/lambda-policy.json" "$WORKDIR/run-registry-scan.zip" "$WORKDIR/ecr-push-trigger.zip"; rmdir "$WORKDIR" 2>/dev/null || true' EXIT

# A new IAM role can take a few seconds to become usable. Retry a command that
# fails for that reason; any other failure is reported straight away.
retry_iam() {
  local attempt out
  for attempt in 1 2 3 4 5 6; do
    if out=$("$@" 2>&1); then return 0; fi
    if echo "$out" | grep -q -E "cannot be assumed|Invalid principal"; then
      echo "  waiting for IAM to propagate (attempt ${attempt}/6)..."
      sleep 10
    else
      echo "$out" >&2
      return 1
    fi
  done
  echo "$out" >&2
  return 1
}

echo "Deploying to account ${ACCOUNT_ID} in ${REGION}"
echo

# ---------------------------------------------------------------------------
echo "Step 0: look up the Sysdig API token secret (${SECRET_NAME})"
# ---------------------------------------------------------------------------
# Secrets Manager appends a random suffix to every secret ARN, and ECS needs
# the full ARN, so resolve it rather than building it from the name.
if ! SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
      --region "$REGION" --query ARN --output text); then
  echo "  ERROR: secret '${SECRET_NAME}' not found in ${REGION}. Create it first (see README)."
  exit 1
fi
echo "  ${SECRET_ARN}"

# ECS injects the whole secret string into the container. If the secret is a
# key/value pair (the console default), that would send the raw JSON to Sysdig
# as the token and fail with a 401. ECS can extract one key via
# "<arn>:<key>::", so find the first key and point the task at it. The value
# is never printed.
SECRET_VALUE_FROM="$SECRET_ARN"
if SECRET_STRING=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
      --region "$REGION" --query SecretString --output text 2>/dev/null); then
  SECRET_KEY=$(printf '%s' "$SECRET_STRING" | jq -r \
    'if type == "object" then (keys_unsorted[0] // empty) else empty end' 2>/dev/null || true)
  SECRET_KEY_COUNT=$(printf '%s' "$SECRET_STRING" | jq -r \
    'if type == "object" then length else 0 end' 2>/dev/null || echo 0)
  if [ -n "$SECRET_KEY" ]; then
    if ! [[ "$SECRET_KEY" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      echo "  ERROR: the first key in the secret has characters this script cannot pass to ECS."
      echo "         Store the token as plain text, or use a key made of letters, digits, _ . -"
      exit 1
    fi
    SECRET_VALUE_FROM="${SECRET_ARN}:${SECRET_KEY}::"
    echo "  secret is key/value: using key '${SECRET_KEY}'"
    if [ "$SECRET_KEY_COUNT" -gt 1 ]; then
      echo "  WARNING: the secret has ${SECRET_KEY_COUNT} keys; using the first ('${SECRET_KEY}')"
    fi
  else
    echo "  secret is plain text"
  fi
else
  echo "  WARNING: could not read the secret value (needs secretsmanager:GetSecretValue)."
  echo "           Assuming it is plain text. If it is key/value, scans will fail with a 401."
fi
unset SECRET_STRING
echo

# ---------------------------------------------------------------------------
echo "Step 1: ECS task role (${TASK_ROLE})"
# ---------------------------------------------------------------------------
if ! aws iam get-role --role-name "$TASK_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$TASK_ROLE" \
    --assume-role-policy-document file://iam/ecs-trust-policy.json >/dev/null
  aws iam wait role-exists --role-name "$TASK_ROLE"
  echo "  created"
else
  echo "  already exists"
fi

# The scanner assumes this same role (REGISTRYSCANNER_CONFIG_AWS_MANAGEMENTACCOUNTROLEARN),
# so the role must trust itself. The role has to exist first to be named as a
# principal. This role belongs to this solution, so its trust policy is
# replaced on every run.
retry_iam aws iam update-assume-role-policy --role-name "$TASK_ROLE" --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"ecs-tasks.amazonaws.com\"},
      \"Action\": \"sts:AssumeRole\"
    },
    {
      \"Effect\": \"Allow\",
      \"Principal\": {\"AWS\": \"arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE}\"},
      \"Action\": \"sts:AssumeRole\"
    }
  ]
}"
aws iam put-role-policy --role-name "$TASK_ROLE" --policy-name assume-self \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"sts:AssumeRole\",
      \"Resource\": \"arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE}\"
    }]
  }"

# Pull images and write task logs.
aws iam attach-role-policy --role-name "$TASK_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam attach-role-policy --role-name "$TASK_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

# The task definition sets awslogs-create-group=true, and the managed policy
# above does not include logs:CreateLogGroup.
aws iam put-role-policy --role-name "$TASK_ROLE" --policy-name create-scanner-log-group \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"logs:CreateLogGroup\",
      \"Resource\": [
        \"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/ecs/Sysdig-Registry-Scanner\",
        \"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/ecs/Sysdig-Registry-Scanner:*\"
      ]
    }]
  }"

# Read the Sysdig API token from Secrets Manager at task start.
aws iam put-role-policy --role-name "$TASK_ROLE" --policy-name read-sysdig-token \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"secretsmanager:GetSecretValue\",
      \"Resource\": \"${SECRET_ARN}\"
    }]
  }"
echo "  policies attached"

# Earlier versions of this script added permissions to the shared default role
# ecsTaskExecutionRole. Point that out, but never touch a role we do not own.
if aws iam get-role-policy --role-name ecsTaskExecutionRole --policy-name assume-self >/dev/null 2>&1; then
  echo "  NOTE: ecsTaskExecutionRole still has permissions added by an earlier version of this"
  echo "        script (assume-self, create-scanner-log-group, read-sysdig-token). The scanner no"
  echo "        longer uses that role. See the README (Migrating from ecsTaskExecutionRole)."
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: Lambda role (${LAMBDA_ROLE})"
# ---------------------------------------------------------------------------
if ! aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$LAMBDA_ROLE" \
    --assume-role-policy-document file://iam/lambda-trust-policy.json >/dev/null
  aws iam wait role-exists --role-name "$LAMBDA_ROLE"
  echo "  created"
else
  echo "  already exists"
fi

# One policy covers both Lambdas (they share this role). It may pass the task role to ECS.
sed -e "s|{{TASK_ROLE}}|${TASK_ROLE}|g" iam/lambda-policy.json > "$WORKDIR/lambda-policy.json"
aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name registry-scanner \
  --policy-document "file://${WORKDIR}/lambda-policy.json"
echo "  policy attached"
echo

# ---------------------------------------------------------------------------
echo "Step 3: ECS cluster (${CLUSTER_NAME})"
# ---------------------------------------------------------------------------
if [ "$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" \
        --query 'clusters[0].status' --output text 2>/dev/null)" != "ACTIVE" ]; then
  aws ecs create-cluster --cluster-name "$CLUSTER_NAME" >/dev/null
  echo "  created"
else
  echo "  already exists"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 4: scanner task definition"
# ---------------------------------------------------------------------------
# Fill the placeholders in the template, then register it.
sed -e "s|{{ACCOUNT_ID}}|${ACCOUNT_ID}|g" \
    -e "s|{{REGION}}|${REGION}|g" \
    -e "s|{{TASK_ROLE}}|${TASK_ROLE}|g" \
    -e "s|{{SYSDIG_API_URL}}|${SYSDIG_API_URL}|g" \
    -e "s|{{ECR_REGISTRY_URL}}|${REGISTRY_URL}|g" \
    -e "s|{{SECURE_SKIPTLS}}|${SECURE_SKIPTLS}|g" \
    -e "s|{{SECRET_VALUE_FROM}}|${SECRET_VALUE_FROM}|g" \
    ecs/task-definition-template.json > "$WORKDIR/task-definition.json"

aws ecs register-task-definition --cli-input-json "file://${WORKDIR}/task-definition.json" >/dev/null
echo "  registered Sysdig-Registry-Scanner (latest revision)"
echo

# ---------------------------------------------------------------------------
echo "Step 5: orchestrator Lambda (run-registry-scan)"
# ---------------------------------------------------------------------------
( cd lambda/run-registry-scan && zip -q "$WORKDIR/run-registry-scan.zip" lambda_function.py )

if aws lambda get-function --function-name run-registry-scan >/dev/null 2>&1; then
  aws lambda update-function-code --function-name run-registry-scan \
    --zip-file "fileb://${WORKDIR}/run-registry-scan.zip" >/dev/null
  echo "  code updated"
else
  retry_iam aws lambda create-function --function-name run-registry-scan \
    --runtime python3.11 --handler lambda_function.lambda_handler \
    --role "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}" \
    --zip-file "fileb://${WORKDIR}/run-registry-scan.zip" \
    --timeout 900 --memory-size 128
  echo "  created"
fi
aws lambda wait function-updated --function-name run-registry-scan
# The Lambda waits for the scan task to finish (up to ~14 minutes), so it needs
# the maximum 15 minute timeout. Set it on every run so older deployments that
# were created with a shorter timeout are corrected too.
aws lambda update-function-configuration --function-name run-registry-scan \
  --timeout 900 >/dev/null
aws lambda wait function-updated --function-name run-registry-scan
echo

# ---------------------------------------------------------------------------
echo "Step 6: trigger Lambda (ecr-push-trigger)"
# ---------------------------------------------------------------------------
( cd lambda/ecr-push-trigger && zip -q "$WORKDIR/ecr-push-trigger.zip" lambda_function.py )

ENV_VARS="Variables={SCANNER_LAMBDA_NAME=run-registry-scan,ECS_CLUSTER=${CLUSTER_NAME},ECS_TASK_DEFINITION=Sysdig-Registry-Scanner,SUBNET_ID=${SUBNET_ID},SECURITY_GROUP_ID=${SECURITY_GROUP_ID}}"

if aws lambda get-function --function-name ecr-push-trigger >/dev/null 2>&1; then
  aws lambda update-function-code --function-name ecr-push-trigger \
    --zip-file "fileb://${WORKDIR}/ecr-push-trigger.zip" >/dev/null
  aws lambda wait function-updated --function-name ecr-push-trigger
  aws lambda update-function-configuration --function-name ecr-push-trigger \
    --environment "$ENV_VARS" >/dev/null
  echo "  code and config updated"
else
  retry_iam aws lambda create-function --function-name ecr-push-trigger \
    --runtime python3.11 --handler lambda_function.lambda_handler \
    --role "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}" \
    --zip-file "fileb://${WORKDIR}/ecr-push-trigger.zip" \
    --timeout 60 --memory-size 128 \
    --environment "$ENV_VARS"
  echo "  created"
fi
aws lambda wait function-updated --function-name ecr-push-trigger
echo

# ---------------------------------------------------------------------------
echo "Step 7: EventBridge rule (scan on ECR push)"
# ---------------------------------------------------------------------------
aws events put-rule --name ecr-push-trigger-scanner --state ENABLED \
  --description "Run a Sysdig scan when an image is pushed to ECR" \
  --event-pattern '{"source":["aws.ecr"],"detail-type":["ECR Image Action"],"detail":{"action-type":["PUSH"],"result":["SUCCESS"]}}' \
  >/dev/null

TRIGGER_ARN=$(aws lambda get-function --function-name ecr-push-trigger \
  --query 'Configuration.FunctionArn' --output text)

# Allow EventBridge to invoke the trigger (ignore error if it already can).
aws lambda add-permission --function-name ecr-push-trigger \
  --statement-id AllowEventBridgeInvoke --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/ecr-push-trigger-scanner" \
  >/dev/null 2>&1 || true

aws events put-targets --rule ecr-push-trigger-scanner \
  --targets "Id=1,Arn=${TRIGGER_ARN}" >/dev/null
echo "  rule wired to ecr-push-trigger"
echo

echo "Done. Push an image to ECR to trigger a scan, or run ./test.sh to scan one now."
