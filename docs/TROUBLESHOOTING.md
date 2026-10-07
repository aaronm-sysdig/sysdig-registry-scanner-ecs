# Troubleshooting

## Quick diagnostic

Run these in order when something isn't working:

```bash
REGION="YOUR_REGION"

# 1. Is the EventBridge rule enabled and wired to the trigger Lambda?
aws events describe-rule --name ecr-push-trigger-scanner --region $REGION \
  --query '[State, EventPattern]' --output json
aws events list-targets-by-rule --rule ecr-push-trigger-scanner --region $REGION

# 2. Check trigger Lambda logs (appeared within seconds of a push)
aws logs tail /aws/lambda/ecr-push-trigger --since 10m --region $REGION

# 3. Check orchestrator Lambda logs (appeared after trigger fires)
aws logs tail /aws/lambda/run-registry-scan --since 10m --region $REGION

# 4. Check scanner task logs (full scanner output)
aws logs tail /ecs/Sysdig-Registry-Scanner --since 10m --region $REGION
```

---

## Push to ECR but no scan starts

**Symptom:** Image pushed, nothing appears in Lambda logs.

**Check:**
1. EventBridge rule exists and is `ENABLED`:
   ```bash
   aws events describe-rule --name ecr-push-trigger-scanner --region YOUR_REGION
   ```

2. The trigger Lambda is the rule target:
   ```bash
   aws events list-targets-by-rule --rule ecr-push-trigger-scanner --region YOUR_REGION
   ```

3. EventBridge has permission to invoke the Lambda:
   ```bash
   aws lambda get-policy --function-name ecr-push-trigger --region YOUR_REGION
   ```
   You should see a statement with `"Principal": "events.amazonaws.com"`.

**Fix:** Re-run `./deploy.sh` - it will recreate the rule, wiring, and permission.

---

## Trigger Lambda logs appear but scanner never starts

**Symptom:** `ecr-push-trigger` logs show it invoked `run-registry-scan`, but the orchestrator logs are empty.

**Check:**
- Confirm the trigger Lambda's `SCANNER_LAMBDA_NAME` environment variable matches the orchestrator function name:
  ```bash
  aws lambda get-function-configuration --function-name ecr-push-trigger \
    --query 'Environment.Variables' --region YOUR_REGION
  ```

- Confirm the Lambda role has `lambda:InvokeFunction` permission on `run-registry-scan`:
  ```bash
  aws iam get-role-policy --role-name lambda-registry-scanner-role --policy-name registry-scanner
  ```

---

## Scan fails (exit code 1)

**Symptom:** The task stops with exit code 1.

Check the ECS scanner logs for the actual error:
```bash
aws logs tail /ecs/Sysdig-Registry-Scanner --since 30m --region YOUR_REGION
```

Common causes:

| Error in logs | Cause | Fix |
|---|---|---|
| `401 Unauthorized` | ECR token not passed or expired | Check Lambda has `ecr:GetAuthorizationToken` permission |
| `manifest unknown` | Image tag does not exist | Verify the image was pushed successfully |
| `connection refused` / timeout to Sysdig | No network path to Sysdig API | Check subnet routing and security group outbound rules |
| `401` from Sysdig API | Invalid API token | Check the secret value in Secrets Manager |
| `no space left on device` | Fargate task ran out of ephemeral storage | Large image - contact Sysdig for scanner configuration guidance |

---

## Scanner Lambda times out (202 response)

**Symptom:** `run-registry-scan` returns HTTP 202 instead of 200.

The orchestrator waits up to about 14 minutes for the Fargate task to stop. A 202 means the task was launched but the waiter timed out before it finished. The scan may still be running.

Check:
```bash
# List running/recent tasks
aws ecs list-tasks --cluster YOUR_CLUSTER_NAME --region YOUR_REGION

# Check scanner logs for progress
aws logs tail /ecs/Sysdig-Registry-Scanner --since 30m --region YOUR_REGION
```

Very large images (multi-GB) can take longer than 14 minutes. In that case the scan completes and sends results to Sysdig even though the Lambda already returned 202.

---

## No results in Sysdig Secure

**Symptom:** Task exits with code 0, but nothing appears under **Vulnerabilities -> Findings -> Registry**.

1. Check the stored token without printing it. A key/value secret starts with `{`, and a Sysdig token is
   usually a UUID of about 36 characters. If the first character is `{`, re-run `./deploy.sh`, which
   points the task at the first key. Then test the token against your Sysdig region's API (expect `200`;
   `/api/user/me` is the usual authenticated endpoint, but use whichever authenticated call your Sysdig
   documentation recommends):
   ```bash
   TOKEN=$(aws secretsmanager get-secret-value --secret-id YOUR_SECRET_NAME \
       --query SecretString --output text --region YOUR_REGION)
   printf 'first char: %s   length: %s\n' "${TOKEN:0:1}" "${#TOKEN}"
   curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer ${TOKEN}" \
       https://app.au1.sysdig.com/api/user/me      # use your Sysdig region URL
   unset TOKEN
   ```

2. Confirm the Sysdig API URL in the task definition is correct:
   ```bash
   aws ecs describe-task-definition --task-definition Sysdig-Registry-Scanner --region YOUR_REGION \
     --query "taskDefinition.containerDefinitions[0].environment[?name=='REGISTRYSCANNER_SECURE_BASEURL']"
   ```

3. Check the scanner logs for API call results - look for lines containing `vm-Client` or `remote-reporter`.

4. Allow a minute or two - results are sometimes delayed in the Sysdig backend.

---

## No logs appearing for trigger or scanner Lambda

**Symptom:** Log groups exist but are empty, or `lastEventTime` is `None`.

The Lambda IAM role needs write access to both log groups. Confirm:
```bash
aws iam get-role-policy --role-name lambda-registry-scanner-role --policy-name registry-scanner \
  --query 'PolicyDocument.Statement[?Sid==`WriteLogs`]'
```

Both `/aws/lambda/run-registry-scan:*` and `/aws/lambda/ecr-push-trigger:*` should be in the Resource list. If not, re-run `./deploy.sh`.

---

## Useful commands

```bash
# View both Lambda configurations
aws lambda get-function-configuration --function-name run-registry-scan --region YOUR_REGION
aws lambda get-function-configuration --function-name ecr-push-trigger --region YOUR_REGION

# View current task definition
aws ecs describe-task-definition --task-definition Sysdig-Registry-Scanner --region YOUR_REGION

# List recent stopped tasks
aws ecs list-tasks --cluster YOUR_CLUSTER_NAME \
  --desired-status STOPPED --region YOUR_REGION

# Check a specific task's exit code
aws ecs describe-tasks --cluster YOUR_CLUSTER_NAME \
  --tasks TASK_ID --region YOUR_REGION \
  --query 'tasks[0].{status:lastStatus,exit:containers[0].exitCode,reason:stoppedReason}'

# Check EventBridge invocation count (last 2 hours)
aws cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name TriggeredRules \
  --dimensions Name=RuleName,Value=ecr-push-trigger-scanner \
  --statistics Sum \
  --start-time $(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --region YOUR_REGION
```
