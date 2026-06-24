# Architecture

## Overview

This solution scans container images in Amazon ECR using Sysdig's registry scanner. It is entirely serverless - there are no always-on compute resources. Each scan is a one-shot Fargate task that starts, scans one image, and exits.

```
ECR push
    |
    v
EventBridge rule (ecr-push-trigger-scanner)
    |
    v
Lambda: ecr-push-trigger       [60s timeout]
    |  extracts image ref from event
    |  invokes orchestrator asynchronously
    v
Lambda: run-registry-scan      [300s timeout]
    |  gets ECR auth token (short-lived)
    |  launches one-shot Fargate task
    |  waits up to 15 min for task to stop
    |  returns exit code 0 (success) / 1 (failure)
    v
ECS Fargate task: Sysdig-Registry-Scanner
    |  runner mode: sbom-exporter
    |  pulls image using token passed from Lambda
    |  extracts SBOM
    |  sends results to Sysdig Secure API
    v
Sysdig Secure
    vulnerability findings, SBOM, policy results
```

## Components

### Lambda: ecr-push-trigger

Triggered by EventBridge whenever an image is successfully pushed to any ECR repository in the account. It extracts the repository name, image tag, account ID, and region from the event, then invokes `run-registry-scan` asynchronously (fire-and-forget). Its own execution completes in under a second.

Environment variables (set by `deploy.sh`):
- `SCANNER_LAMBDA_NAME` - orchestrator function to invoke
- `ECS_CLUSTER` - cluster to run the task in
- `ECS_TASK_DEFINITION` - unqualified family name; ECS resolves to the latest active revision
- `SUBNET_ID` - subnet for the Fargate task
- `SECURITY_GROUP_ID` - security group for the Fargate task

### Lambda: run-registry-scan

The orchestrator. Receives the image reference from the trigger, generates a short-lived ECR auth token using its own IAM role, launches the Fargate scanner task with credentials and the image name passed as environment overrides, then waits (polling every 10 seconds, up to 15 minutes) for the task to stop. Returns the task's exit code as the scan result.

Input payload:
```json
{
  "image_to_scan": "my-repo:v1.0.0",
  "registry_url": "123456789012.dkr.ecr.ap-southeast-2.amazonaws.com",
  "cluster": "Sysdig-Fargate-Test-Cluster",
  "task_definition": "Sysdig-Registry-Scanner",
  "subnet": "subnet-xxxxxxxxx",
  "security_groups": ["sg-xxxxxxxxx"]
}
```

### ECS Fargate task: Sysdig-Registry-Scanner

Runs `quay.io/sysdig/registry-scanner` in `sbom-exporter` mode (`--scan_runner=sbom-exporter`). Each invocation is one-shot: scan one image, exit. There is no long-running service; the ECS cluster is a logical namespace that Fargate requires but holds no persistent compute.

The Sysdig API token is injected at task startup from AWS Secrets Manager (via the ECS task execution role). The ECR credentials are passed as environment overrides by the orchestrator Lambda each time the task is launched - this is necessary because the scanner's image-pull component requires explicit Basic Auth credentials rather than using the IAM role directly.

### EventBridge rule: ecr-push-trigger-scanner

Matches all successful ECR push events in the account:
```json
{
  "source": ["aws.ecr"],
  "detail-type": ["ECR Image Action"],
  "detail": {
    "action-type": ["PUSH"],
    "result": ["SUCCESS"]
  }
}
```

No repository filter is applied - every push triggers a scan. To restrict to specific repositories, add a `"repository-name"` filter to the event pattern.

## IAM

### lambda-registry-scanner-role

Shared by both Lambdas. One consolidated inline policy (`registry-scanner`) grants:
- `logs:CreateLogGroup/Stream/PutLogEvents` - write to both Lambda log groups
- `ecr:GetAuthorizationToken` + read actions - generate and use ECR tokens
- `ecs:RunTask`, `ecs:DescribeTasks` - launch and monitor scanner tasks
- `iam:PassRole` - pass `ecsTaskExecutionRole` to the Fargate task
- `lambda:InvokeFunction` - trigger Lambda invokes the orchestrator

### ecsTaskExecutionRole

Used by the Fargate task. AWS-managed policies:
- `AmazonECSTaskExecutionRolePolicy` - pull images, write CloudWatch logs
- `AmazonEC2ContainerRegistryReadOnly` - read ECR images

Custom inline policy:
- `secretsmanager:GetSecretValue` - read the Sysdig API token at task start

## Network

The Fargate task needs outbound HTTPS (port 443) to reach:
- `*.dkr.ecr.REGION.amazonaws.com` - ECR image registry
- `s3.REGION.amazonaws.com` - ECR image layer storage (S3-backed)
- Your Sysdig API endpoint (e.g. `app.au1.sysdig.com`)

The simplest setup is a public subnet with an Internet Gateway. For production, a private subnet with a NAT gateway is recommended.

No inbound connections are required.

## Logging

| Log group | Contents |
|---|---|
| `/aws/lambda/ecr-push-trigger` | Event received, image ref extracted, orchestrator invoked |
| `/aws/lambda/run-registry-scan` | ECR token generation, task launch, wait status, exit code |
| `/ecs/Sysdig-Registry-Scanner` | Full scanner output: image pull, SBOM extraction, Sysdig API calls |

## Scaling

- Lambda scales automatically up to the account concurrency limit (default 1000)
- ECS Fargate task limit is 500 concurrent per account (soft limit, can be increased)
- One Lambda invocation per push event; one Fargate task per Lambda invocation
- For high push volumes, consider adding an SQS queue between the trigger and orchestrator

## Cost estimate

Per scan (ap-southeast-2 pricing):
- Lambda (`run-registry-scan`, ~60s at 128MB): ~$0.0001
- Fargate (1 vCPU, 2GB, ~60s): ~$0.002
- CloudWatch Logs ingestion: ~$0.00005
- **Total: ~$0.002 per scan**
