# GitHub Repository Guide

**Repository:** https://github.com/aaronm-sysdig/sysdig-registry-scanner-ecs

**Purpose:** AWS Lambda + ECS Fargate deployment for Sysdig Registry Scanner. Provides automatic on-push scanning of ECR images, sending results to Sysdig Secure.

## Quick setup

```bash
git clone git@github.com:aaronm-sysdig/sysdig-registry-scanner-ecs.git
cd sysdig-registry-scanner-ecs

# 1. Store your Sysdig API token in Secrets Manager (see README)
# 2. Edit the CONFIG block at the top of deploy.sh
# 3. Deploy
chmod +x deploy.sh test.sh
./deploy.sh

# 4. Test
./test.sh
```

See [QUICKSTART.md](QUICKSTART.md) for the full walkthrough or [README.md](README.md) for complete documentation.

## Repository structure

```
deploy.sh                            - deploys the complete solution
test.sh                              - invokes a scan directly for testing
iam/                                 - IAM policy documents
ecs/                                 - ECS task definition template
lambda/
  run-registry-scan/                 - orchestrator Lambda
  ecr-push-trigger/                  - EventBridge trigger Lambda
docs/
  ARCHITECTURE.md                    - how it works
  TROUBLESHOOTING.md                 - common issues
QUICKSTART.md                        - 5-minute setup guide
DEPLOYMENT_CHECKLIST.md              - customer deployment checklist
```

## Keeping up to date

```bash
cd sysdig-registry-scanner-ecs
git pull origin main
```

After pulling, re-run `./deploy.sh` to apply any changes to Lambda code or the task definition.

`deploy.sh` has a CONFIG block you edit in place, so `git pull` refuses if you changed it. Keep your values with:

```bash
git stash && git pull origin main && git stash pop
```

If `git stash pop` reports a conflict in the CONFIG block, keep the new file and re-enter your values.
`./update-test.sh` registers new scanner image versions directly and updates `ecs/task-definition-template.json`,
so commit or stash that file change before pulling.

## Making changes

```bash
# Create a feature branch
git checkout -b feature/my-change

# Make your changes, then commit
git add .
git commit -m "Description of change"
git push origin feature/my-change
```

Open a pull request against `main` on GitHub.

## Deploying to a new customer

1. Clone the repo
2. Edit the CONFIG block in `deploy.sh` with the customer's AWS details
3. Follow `DEPLOYMENT_CHECKLIST.md`

Each customer deployment is independent - the resources are created in their own AWS account. The repo itself contains no account-specific values; those live only in the local copy of `deploy.sh` used for that deployment.

## Reporting issues

https://github.com/aaronm-sysdig/sysdig-registry-scanner-ecs/issues

Include:
- AWS region
- Which step failed
- Relevant CloudWatch log output

## Maintainers

- Aaron Miles (@aaronm-sysdig) - Sysdig, Inc.
