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
ACCOUNT_ID="123456789012"
SUBNET_ID="subnet-xxxxxxxxx"                   # must have outbound internet (public or NAT)
SECURITY_GROUP_ID="sg-xxxxxxxxx"               # must allow outbound HTTPS (443)
SYSDIG_API_URL="https://app.au1.sysdig.com"
SECRET_NAME="SECURE_API_TOKEN"                 # Secrets Manager secret holding the Sysdig API token
CLUSTER_NAME="Sysdig-Fargate-Test-Cluster"
# ---------------------------------------------------------------------------

REGISTRY_URL="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
LAMBDA_ROLE="lambda-registry-scanner-role"
TASK_ROLE="ecsTaskExecutionRole"
cd "$(dirname "$0")"

echo "Deploying to account ${ACCOUNT_ID} in ${REGION}"
echo

# ---------------------------------------------------------------------------
echo "Step 1: ECS task execution role (${TASK_ROLE})"
# ---------------------------------------------------------------------------
if ! aws iam get-role --role-name "$TASK_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$TASK_ROLE" \
    --assume-role-policy-document file://iam/ecs-trust-policy.json >/dev/null
  echo "  created"
  sleep 10   # let the role propagate
else
  echo "  already exists"
fi

# Pull images and write task logs.
aws iam attach-role-policy --role-name "$TASK_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam attach-role-policy --role-name "$TASK_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

# Read the Sysdig API token from Secrets Manager at task start.
aws iam put-role-policy --role-name "$TASK_ROLE" --policy-name read-sysdig-token \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"secretsmanager:GetSecretValue\",
      \"Resource\": \"arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:${SECRET_NAME}*\"
    }]
  }"
echo "  policies attached"
echo

# ---------------------------------------------------------------------------
echo "Step 2: Lambda role (${LAMBDA_ROLE})"
# ---------------------------------------------------------------------------
if ! aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$LAMBDA_ROLE" \
    --assume-role-policy-document file://iam/lambda-trust-policy.json >/dev/null
  echo "  created"
  sleep 10
else
  echo "  already exists"
fi

# One policy covers both Lambdas (they share this role).
aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name registry-scanner \
  --policy-document file://iam/lambda-policy.json
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
    -e "s|{{SYSDIG_API_URL}}|${SYSDIG_API_URL}|g" \
    -e "s|{{ECR_REGISTRY_URL}}|${REGISTRY_URL}|g" \
    -e "s|{{SECRET_NAME}}|${SECRET_NAME}|g" \
    ecs/task-definition-template.json > /tmp/task-definition.json

aws ecs register-task-definition --cli-input-json file:///tmp/task-definition.json >/dev/null
echo "  registered Sysdig-Registry-Scanner (latest revision)"
echo

# ---------------------------------------------------------------------------
echo "Step 5: orchestrator Lambda (run-registry-scan)"
# ---------------------------------------------------------------------------
( cd lambda/run-registry-scan && zip -q -r /tmp/run-registry-scan.zip lambda_function.py )

if aws lambda get-function --function-name run-registry-scan >/dev/null 2>&1; then
  aws lambda update-function-code --function-name run-registry-scan \
    --zip-file fileb:///tmp/run-registry-scan.zip >/dev/null
  echo "  code updated"
else
  aws lambda create-function --function-name run-registry-scan \
    --runtime python3.11 --handler lambda_function.lambda_handler \
    --role "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}" \
    --zip-file fileb:///tmp/run-registry-scan.zip \
    --timeout 300 --memory-size 128 >/dev/null
  echo "  created"
fi
aws lambda wait function-updated --function-name run-registry-scan
echo

# ---------------------------------------------------------------------------
echo "Step 6: trigger Lambda (ecr-push-trigger)"
# ---------------------------------------------------------------------------
( cd lambda/ecr-push-trigger && zip -q -r /tmp/ecr-push-trigger.zip lambda_function.py )

ENV_VARS="Variables={SCANNER_LAMBDA_NAME=run-registry-scan,ECS_CLUSTER=${CLUSTER_NAME},ECS_TASK_DEFINITION=Sysdig-Registry-Scanner,SUBNET_ID=${SUBNET_ID},SECURITY_GROUP_ID=${SECURITY_GROUP_ID}}"

if aws lambda get-function --function-name ecr-push-trigger >/dev/null 2>&1; then
  aws lambda update-function-code --function-name ecr-push-trigger \
    --zip-file fileb:///tmp/ecr-push-trigger.zip >/dev/null
  aws lambda wait function-updated --function-name ecr-push-trigger
  aws lambda update-function-configuration --function-name ecr-push-trigger \
    --environment "$ENV_VARS" >/dev/null
  echo "  code and config updated"
else
  aws lambda create-function --function-name ecr-push-trigger \
    --runtime python3.11 --handler lambda_function.lambda_handler \
    --role "arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE}" \
    --zip-file fileb:///tmp/ecr-push-trigger.zip \
    --timeout 60 --memory-size 128 \
    --environment "$ENV_VARS" >/dev/null
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
