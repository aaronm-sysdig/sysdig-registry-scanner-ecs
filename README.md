# Sysdig Registry Scanner - AWS ECS Deployment

An on-push ECR image scanning solution built on AWS Lambda and ECS Fargate. When an image is pushed to ECR, a scan is automatically triggered via EventBridge. The Sysdig registry scanner runs as a one-shot Fargate task, extracts the SBOM, and sends vulnerability results to your Sysdig Secure instance.

## How it works

```
ECR push -> EventBridge -> ecr-push-trigger -> run-registry-scan -> Fargate task -> Sysdig Secure
```

1. An image is pushed to ECR
2. EventBridge fires the trigger Lambda (`ecr-push-trigger`)
3. The trigger invokes the orchestrator Lambda (`run-registry-scan`) asynchronously
4. The orchestrator gets a short-lived ECR token and launches a one-shot Fargate task
5. The Fargate task runs the Sysdig scanner in sbom-exporter mode
6. The scanner pulls the image, extracts the SBOM, and sends results to Sysdig Secure
7. The task exits with code 0 (success) or 1 (failure)

## Prerequisites

- AWS account with admin access
- AWS CLI configured
- `jq` installed
- Sysdig Secure account and API token
- A VPC subnet with outbound internet access (public subnet, or private with NAT gateway)
- A security group allowing outbound HTTPS (port 443)

## Deployment

### 1. Store your Sysdig API token in Secrets Manager

```bash
aws secretsmanager create-secret \
    --name SECURE_API_TOKEN \
    --secret-string "YOUR_SYSDIG_API_TOKEN" \
    --region YOUR_REGION
```

### 2. Edit the config block in deploy.sh

Open `deploy.sh` and update the CONFIG section at the top:

```bash
REGION="ap-southeast-2"
ACCOUNT_ID="123456789012"
SUBNET_ID="subnet-xxxxxxxxx"        # must have outbound internet access
SECURITY_GROUP_ID="sg-xxxxxxxxx"    # must allow outbound HTTPS (443)
SYSDIG_API_URL="https://app.au1.sysdig.com"
SECRET_NAME="SECURE_API_TOKEN"
CLUSTER_NAME="Sysdig-Fargate-Test-Cluster"
```

Sysdig region URLs:
- AU: `https://app.au1.sysdig.com`
- US East: `https://app.sysdigcloud.com`
- US West: `https://us2.app.sysdig.com`
- EU: `https://eu1.app.sysdig.com`

### 3. Deploy

```bash
chmod +x deploy.sh test.sh
./deploy.sh
```

The script deploys everything in one run:
- IAM roles for the Lambdas and the Fargate task
- ECS cluster (logical only - Fargate needs no nodes to manage)
- Scanner task definition
- `run-registry-scan` Lambda (orchestrator)
- `ecr-push-trigger` Lambda (EventBridge trigger)
- EventBridge rule that fires on every successful ECR push

Re-running is safe - it updates existing resources rather than erroring.

### 4. Test

Edit the CONFIG block at the top of `test.sh` to point at an image that exists in your ECR, then run:

```bash
./test.sh
```

This invokes the orchestrator Lambda directly with a specific image and waits for the scan to complete. Useful for a quick end-to-end check without needing to do an ECR push.

## AWS resources created

| Resource | Name |
|---|---|
| IAM role (Lambdas) | `lambda-registry-scanner-role` |
| IAM role (Fargate task) | `ecsTaskExecutionRole` |
| Lambda | `run-registry-scan` (timeout: 300s) |
| Lambda | `ecr-push-trigger` (timeout: 60s) |
| ECS cluster | `Sysdig-Fargate-Test-Cluster` (configurable) |
| ECS task definition | `Sysdig-Registry-Scanner` |
| EventBridge rule | `ecr-push-trigger-scanner` |

## Viewing results

### In Sysdig Secure

1. Log into your Sysdig Secure instance
2. Navigate to: **Vulnerabilities -> Findings -> Registry**
3. Search for the scanned image

### CloudWatch logs

```bash
# Trigger Lambda
aws logs tail /aws/lambda/ecr-push-trigger --follow --region YOUR_REGION

# Orchestrator Lambda
aws logs tail /aws/lambda/run-registry-scan --follow --region YOUR_REGION

# Scanner task output
aws logs tail /ecs/Sysdig-Registry-Scanner --follow --region YOUR_REGION
```

## Troubleshooting

### "Essential container in task exited"

This is normal - it is ECS's message when a one-shot task finishes. Check the exit code:
- Exit code `0` = scan succeeded
- Exit code `1` = scan failed - check `/ecs/Sysdig-Registry-Scanner` logs

### Push to ECR but no scan triggered

1. Confirm the EventBridge rule exists and is ENABLED:
   ```bash
   aws events describe-rule --name ecr-push-trigger-scanner --region YOUR_REGION
   ```
2. Confirm the trigger Lambda is wired as the target:
   ```bash
   aws events list-targets-by-rule --rule ecr-push-trigger-scanner --region YOUR_REGION
   ```
3. Check EventBridge has permission to invoke the Lambda:
   ```bash
   aws lambda get-policy --function-name ecr-push-trigger --region YOUR_REGION
   ```

### Scan fails (exit code 1)

Check the ECS task logs for the root cause:
```bash
aws logs tail /ecs/Sysdig-Registry-Scanner --since 30m --region YOUR_REGION
```
Common causes: ECR auth error, image not found, no network route to Sysdig API, invalid API token.

### Lambda times out (202 response)

The orchestrator waits up to 15 minutes for the task to stop. A 202 means the task started but the waiter hit its limit - the scan may still be running. Check ECS:
```bash
aws ecs list-tasks --cluster Sysdig-Fargate-Test-Cluster --region YOUR_REGION
aws logs tail /ecs/Sysdig-Registry-Scanner --since 30m --region YOUR_REGION
```

### No results in Sysdig Secure

Scan completed (exit code 0) but nothing appears in the console:
1. Verify the API token in Secrets Manager is valid
2. Confirm `REGISTRYSCANNER_SECURE_BASEURL` in the task definition matches your Sysdig region
3. Confirm the subnet/security group allows outbound HTTPS to the Sysdig API endpoint

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a detailed breakdown of the components, IAM design, authentication flow, and network requirements.

## Bulk scanning

`scan-all.sh` scans every tagged ECR image in your account pushed within a given age window, running scans in parallel batches.

```bash
# Scan everything pushed in the last year (default)
./scan-all.sh

# Last 30 days only, 5 scans at a time
./scan-all.sh --max-age-days 30 --batch-size 5

# Preview what would be scanned without invoking anything
./scan-all.sh --dry-run

# Scan all tagged images regardless of age
./scan-all.sh --max-age-days 36500
```

Edit the CONFIG block at the top of `scan-all.sh` the same way as `deploy.sh` - set your account ID, subnet, security group, and region. Output shows per-image pass/fail with timing, batch progress, and a final summary:

```
Found 24 images across 8 repositories
Batch size: 10 | Batches: 3 | Max age: 365 days

--- Batch 1/3 (images 1-10) ---
  [  1/24] my-app:v1.2.3                                          launched
  [  2/24] my-app:v1.2.2                                          launched
  ...
  Waiting for batch 1/3...
  [  1/24] my-app:v1.2.3                                          SUCCESS  (58s)
  [  2/24] my-app:v1.2.2                                          SUCCESS  (61s)
  ...
  Batch 1/3 done: 10 passed, 0 failed
  Progress: 10/24 scanned (41%) | passed: 10 | failed: 0

==============================
 Scan complete
 Total:    24
 Passed:   23
 Failed:    1
 Duration: 4m 12s
==============================
```

## Repository structure

```
deploy.sh                            - deploys the complete solution (edit CONFIG block first)
test.sh                              - invokes a scan directly for testing
scan-all.sh                          - bulk-scans all ECR images in the account
iam/
  lambda-trust-policy.json           - trust policy for the Lambda IAM role
  lambda-policy.json                 - permissions for both Lambdas (single consolidated policy)
  ecs-trust-policy.json              - trust policy for the Fargate task role
ecs/
  task-definition-template.json      - scanner task definition (placeholders filled by deploy.sh)
lambda/
  run-registry-scan/
    lambda_function.py               - orchestrator Lambda
  ecr-push-trigger/
    lambda_function.py               - EventBridge trigger Lambda
docs/
  ARCHITECTURE.md                    - detailed architecture documentation
  TROUBLESHOOTING.md                 - common issues and fixes
```
