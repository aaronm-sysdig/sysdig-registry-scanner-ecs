# Deployment Checklist

Use this when deploying to a customer environment.

## Pre-deployment

### Gather information

- [ ] AWS Account ID: ______________________
- [ ] AWS Region: ______________________
- [ ] VPC Subnet ID (needs outbound internet): ______________________
- [ ] Security Group ID (allows outbound 443): ______________________
- [ ] Sysdig API URL: ______________________
- [ ] Sysdig API Token: ______________________

### Verify prerequisites

- [ ] AWS CLI installed and configured with admin access
- [ ] `jq` installed
- [ ] Subnet has internet access (public subnet or private with NAT gateway)
- [ ] Security group allows outbound HTTPS (port 443)

### Store the API token

- [ ] Sysdig API token stored in AWS Secrets Manager:
  ```bash
  aws secretsmanager create-secret \
      --name SECURE_API_TOKEN \
      --secret-string "YOUR_SYSDIG_API_TOKEN" \
      --region YOUR_REGION
  ```

## Deployment

### Edit and run deploy.sh

- [ ] Edit the CONFIG block at the top of `deploy.sh` with the customer's values
- [ ] Run `./deploy.sh` and confirm no errors

### Confirm resources created

- [ ] IAM role: `lambda-registry-scanner-role` (one inline policy: `registry-scanner`)
- [ ] IAM role: `ecsTaskExecutionRole`
- [ ] ECS cluster: as configured in `deploy.sh`
- [ ] ECS task definition: `Sysdig-Registry-Scanner` (latest revision)
- [ ] Lambda: `run-registry-scan` (timeout: 300s)
- [ ] Lambda: `ecr-push-trigger` (timeout: 60s)
- [ ] EventBridge rule: `ecr-push-trigger-scanner` (ENABLED, target: `ecr-push-trigger`)

## Testing

### Run test.sh

- [ ] Edit the CONFIG block in `test.sh` with a test image that exists in the customer's ECR
- [ ] Run `./test.sh`
- [ ] Response shows `"statusCode": 200` and `"success": true`

### Verify Lambda logs

- [ ] Lambda logs show:
  - ECR token generated
  - Task launched
  - Scan completed, exit code 0
  ```bash
  aws logs tail /aws/lambda/run-registry-scan --since 10m --region YOUR_REGION
  ```

### Verify scanner logs

- [ ] ECS logs show scan completed successfully:
  ```bash
  aws logs tail /ecs/Sysdig-Registry-Scanner --since 10m --region YOUR_REGION
  ```

### Verify results in Sysdig Secure

- [ ] Log into the customer's Sysdig Secure instance
- [ ] Navigate to: **Vulnerabilities -> Findings -> Registry**
- [ ] Test image appears with scan results and a recent timestamp

### Verify end-to-end trigger (push test)

- [ ] Push an image to the customer's ECR
- [ ] Confirm EventBridge fires (check trigger Lambda logs within ~5s of push):
  ```bash
  aws logs tail /aws/lambda/ecr-push-trigger --since 2m --region YOUR_REGION
  ```
- [ ] Confirm scan completes and result appears in Sysdig

## Handoff

- [ ] Customer has access to Sysdig Secure console
- [ ] Customer knows where to find scan results (**Vulnerabilities -> Findings -> Registry**)
- [ ] Customer has the CloudWatch log group names for troubleshooting
- [ ] Customer has a copy of `deploy.sh` with their values (for redeployment if needed)
- [ ] API token rotation process documented for customer

---

**Deployed by:** ______________________
**Date:** ______________________
**Customer:** ______________________
**Region:** ______________________
**Notes:**
