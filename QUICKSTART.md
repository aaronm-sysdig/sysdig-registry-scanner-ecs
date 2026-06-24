# Quick Start Guide

Get the Sysdig registry scanner running on AWS in about 10 minutes.

## What you need

- AWS account with admin access, AWS CLI configured
- `jq` installed
- Sysdig Secure account and API token
- A VPC subnet with outbound internet and a security group allowing outbound HTTPS (443)

## Steps

### 1. Store your Sysdig API token

```bash
aws secretsmanager create-secret \
    --name SECURE_API_TOKEN \
    --secret-string "YOUR_SYSDIG_API_TOKEN" \
    --region YOUR_REGION
```

### 2. Edit deploy.sh

Open `deploy.sh` and update the CONFIG block at the top:

```bash
REGION="ap-southeast-2"
ACCOUNT_ID="123456789012"
SUBNET_ID="subnet-xxxxxxxxx"
SECURITY_GROUP_ID="sg-xxxxxxxxx"
SYSDIG_API_URL="https://app.au1.sysdig.com"   # update to your region
SECRET_NAME="SECURE_API_TOKEN"
CLUSTER_NAME="Sysdig-Fargate-Test-Cluster"
```

### 3. Deploy

```bash
chmod +x deploy.sh test.sh
./deploy.sh
```

This creates all required resources: IAM roles, ECS cluster, task definition, both Lambdas, and the EventBridge rule.

### 4. Test

Edit the CONFIG block in `test.sh` to set an image that exists in your ECR, then run:

```bash
./test.sh
```

Expected output:
```json
{
  "statusCode": 200,
  "body": {
    "success": true,
    "exit_code": 0,
    "message": "Scan completed successfully for your-image:tag"
  }
}
```

### 5. Verify results in Sysdig Secure

1. Log into your Sysdig Secure instance
2. Navigate to: **Vulnerabilities -> Findings -> Registry**
3. Search for your scanned image

## How it works from here

Every image pushed to any ECR repository in your account will now be automatically scanned:

```
ECR push -> EventBridge -> ecr-push-trigger -> run-registry-scan -> Fargate task -> Sysdig Secure
```

No further configuration is needed. To scan a specific image on demand, invoke the Lambda directly:

```bash
aws lambda invoke \
    --function-name run-registry-scan \
    --payload '{
      "image_to_scan": "my-repo:v1.0.0",
      "registry_url": "123456789012.dkr.ecr.ap-southeast-2.amazonaws.com",
      "cluster": "Sysdig-Fargate-Test-Cluster",
      "subnet": "subnet-xxxxxxxxx",
      "security_groups": ["sg-xxxxxxxxx"]
    }' \
    --cli-binary-format raw-in-base64-out \
    --region YOUR_REGION \
    response.json && cat response.json | jq .
```

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common issues, or [README.md](README.md) for full documentation.
