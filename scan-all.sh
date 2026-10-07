#!/bin/bash
#
# Scans all tagged ECR images pushed within the last MAX_AGE_DAYS days.
# Invokes run-registry-scan in parallel batches, waits for each batch,
# then prints a progress summary.
#
# Usage:
#   ./scan-all.sh [--batch-size N] [--max-age-days N] [--region REGION] [--dry-run]
#
# Options:
#   --batch-size N     number of scans to run in parallel (default: 10)
#   --max-age-days N   only scan images pushed within this many days; 0 = no age limit (default: 365)
#   --region REGION    AWS region (default: value in CONFIG block below)
#   --dry-run          discover and list images without invoking any scans
#
# Examples:
#   ./scan-all.sh                              # scan everything pushed in the last year
#   ./scan-all.sh --max-age-days 30            # last 30 days only
#   ./scan-all.sh --batch-size 5              # 5 scans at a time
#   ./scan-all.sh --dry-run                   # preview what would be scanned
#   ./scan-all.sh --dry-run --max-age-days 0  # list all tagged images regardless of age

set -e

# ---------------------------------------------------------------------------
# CONFIG - edit these for your environment
# ---------------------------------------------------------------------------
REGION="ap-southeast-2"
ACCOUNT_ID=""                                  # optional: empty = the account you are logged in to; if set it must match
CLUSTER=""                                     # empty = what the deployed ecr-push-trigger Lambda uses
SUBNET=""                                      # empty = what the deployed ecr-push-trigger Lambda uses
SECURITY_GROUP=""                              # empty = what the deployed ecr-push-trigger Lambda uses
LAMBDA="run-registry-scan"
# ---------------------------------------------------------------------------

BATCH_SIZE=10
MAX_AGE_DAYS=365
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --batch-size)   BATCH_SIZE="$2";   shift 2 ;;
    --max-age-days) MAX_AGE_DAYS="$2"; shift 2 ;;
    --region)       REGION="$2";       shift 2 ;;
    --dry-run)      DRY_RUN=true;      shift   ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

for tool in aws jq; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required but not installed."; exit 1; }
done
if ! [[ "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --batch-size must be a whole number of 1 or more."
  exit 1
fi
if ! [[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --max-age-days must be a whole number (0 = no age limit)."
  exit 1
fi

# Act on the account you are authenticated to, in the chosen region.
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
echo

# ---------------------------------------------------------------------------
# Scan settings: a value set in the CONFIG block wins; an empty one is read
# from the deployed ecr-push-trigger Lambda (what deploy.sh configured). The
# source of each value is logged, and a CONFIG value that differs from what the
# deployed trigger uses is flagged. A dry run resolves them too, so it shows
# what a real run would use.
# ---------------------------------------------------------------------------
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

echo "Scan settings:"
resolve_setting CLUSTER ECS_CLUSTER Sysdig-Fargate-Test-Cluster
resolve_setting SUBNET SUBNET_ID
resolve_setting SECURITY_GROUP SECURITY_GROUP_ID
echo

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
if [ "$MAX_AGE_DAYS" -eq 0 ]; then
  CUTOFF="1970-01-01T00:00:00"
else
  CUTOFF=$(date -u -v-${MAX_AGE_DAYS}d +%Y-%m-%dT%H:%M:%S 2>/dev/null \
        || date -u -d "${MAX_AGE_DAYS} days ago" +%Y-%m-%dT%H:%M:%S)
fi

# ---------------------------------------------------------------------------
# Discover images
# ---------------------------------------------------------------------------
echo "Discovering ECR repositories in ${REGION}..."

if ! REPO_LIST=$(aws ecr describe-repositories \
      --query 'repositories[*].repositoryName' --output text 2>&1); then
  echo "ERROR: could not list ECR repositories: ${REPO_LIST}"
  exit 1
fi

IMAGES=()
SKIPPED_REPOS=0
REPO_COUNT=0

# ECR repository names cannot contain spaces or glob characters, so splitting is safe.
for REPO in $(echo "$REPO_LIST" | tr '\t' '\n'); do
  REPO_COUNT=$(( REPO_COUNT + 1 ))
  # JSON output + jq gives one tag per line (text output is tab-separated).
  if ! TAG_JSON=$(aws ecr describe-images --repository-name "$REPO" \
        --query "imageDetails[?imagePushedAt >= '${CUTOFF}' && length(imageTags) > \`0\`].imageTags[0]" \
        --output json 2>&1); then
    echo "  WARNING: could not list images in ${REPO}: $(echo "$TAG_JSON" | tr '\n' ' ' | cut -c1-200)"
    SKIPPED_REPOS=$(( SKIPPED_REPOS + 1 ))
    continue
  fi
  while IFS= read -r TAG; do
    [[ -z "$TAG" || "$TAG" == "null" ]] && continue
    IMAGES+=("${REPO}:${TAG}")
  done < <(echo "$TAG_JSON" | jq -r '.[]')
done

TOTAL=${#IMAGES[@]}

if [[ $TOTAL -eq 0 ]]; then
  echo "No tagged images found in ${REPO_COUNT} repositories pushed within the last ${MAX_AGE_DAYS} days."
  if [[ $SKIPPED_REPOS -gt 0 ]]; then
    echo "${SKIPPED_REPOS} repositories could not be read (see warnings above)."
    exit 1
  fi
  exit 0
fi

BATCHES=$(( (TOTAL + BATCH_SIZE - 1) / BATCH_SIZE ))

echo "Found ${TOTAL} images across ${REPO_COUNT} repositories"
[[ $SKIPPED_REPOS -gt 0 ]] && echo "WARNING: ${SKIPPED_REPOS} repositories could not be read and are NOT included"
echo "Batch size: ${BATCH_SIZE} | Batches: ${BATCHES} | Max age: ${MAX_AGE_DAYS} days (0 = no limit)"
$DRY_RUN && echo "(dry run - Lambda will not be invoked)"
echo

# ---------------------------------------------------------------------------
# Scan in batches
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SCANNED=0
START_TIME=$(date +%s)

# One line per image (status, image, ECS task id, seconds, message) so failed
# tasks can be looked up afterwards: tail the task's logs with
#   aws logs tail /ecs/Sysdig-Registry-Scanner --since 1h | grep <task_id>
RESULTS_FILE="scan-all-results-$(date +%Y%m%d-%H%M%S).tsv"
if ! $DRY_RUN; then
  printf 'status\timage\ttask_id\tseconds\tmessage\n' > "$RESULTS_FILE"
  echo "Results file: ${RESULTS_FILE}"
  echo
fi

print_progress() {
  local pct=$(( SCANNED * 100 / TOTAL ))
  printf "  Progress: %d/%d scanned (%d%%) | passed: %d | failed: %d\n" \
    "$SCANNED" "$TOTAL" "$pct" "$PASS" "$FAIL"
}

for (( BATCH=0; BATCH<BATCHES; BATCH++ )); do
  BATCH_NUM=$(( BATCH + 1 ))
  OFFSET=$(( BATCH * BATCH_SIZE ))
  COUNT=$(( BATCH_SIZE < TOTAL - OFFSET ? BATCH_SIZE : TOTAL - OFFSET ))

  echo "--- Batch ${BATCH_NUM}/${BATCHES} (images $(( OFFSET + 1 ))-$(( OFFSET + COUNT ))) ---"

  # Per-image tracking for this batch, indexed by position in the batch.
  # (Indexed arrays only, so this runs on macOS's bash 3.2 as well.)
  BATCH_IMAGES=()
  BATCH_FILES=()
  BATCH_TIMES=()

  for (( I=0; I<COUNT; I++ )); do
    IMAGE="${IMAGES[$(( OFFSET + I ))]}"
    LABEL=$(( OFFSET + I + 1 ))
    TMPFILE=$(mktemp /tmp/scan-XXXXXX)
    BATCH_IMAGES[I]="$IMAGE"
    BATCH_FILES[I]="$TMPFILE"
    BATCH_TIMES[I]=$(date +%s)

    printf "  [%3d/%-3d] %-55s" "$LABEL" "$TOTAL" "$IMAGE"

    if $DRY_RUN; then
      echo "skipped"
      rm -f "$TMPFILE"
      continue
    fi

    PAYLOAD=$(printf '{
      "image_to_scan":   "%s",
      "registry_url":    "%s",
      "cluster":         "%s",
      "task_definition": "Sysdig-Registry-Scanner",
      "subnet":          "%s",
      "security_groups": ["%s"]
    }' "$IMAGE" "$REGISTRY" "$CLUSTER" "$SUBNET" "$SECURITY_GROUP")

    aws lambda invoke \
      --function-name "$LAMBDA" \
      --payload "$PAYLOAD" \
      --cli-binary-format raw-in-base64-out \
      --region "$REGION" \
      --cli-read-timeout 1200 \
      "$TMPFILE" >/dev/null 2>"${TMPFILE}.err" &

    echo "launched"
  done

  $DRY_RUN && { echo; continue; }

  echo "  Waiting for batch ${BATCH_NUM}/${BATCHES}..."
  wait

  BATCH_PASS=0
  BATCH_FAIL=0

  for (( I=0; I<COUNT; I++ )); do
    IMAGE="${BATCH_IMAGES[I]}"
    TMPFILE="${BATCH_FILES[I]}"
    LABEL=$(( OFFSET + I + 1 ))
    ELAPSED=$(( $(date +%s) - ${BATCH_TIMES[I]} ))
    # Read everything we need before deleting the response file.
    STATUS=$(jq -r '.statusCode // "none"' "$TMPFILE" 2>/dev/null || echo "none")
    # The Lambda returns {statusCode, body}. If the Lambda itself fails (for
    # example a timeout) there is no body, only an errorMessage.
    MSG=$(jq -r 'if .body then (.body | fromjson | (.message // .error // "unknown"))
                 else (.errorMessage // "no response from Lambda") end' "$TMPFILE" 2>/dev/null \
          || echo "response not readable")
    MSG="${MSG:-no response from Lambda}"
    DETAIL=$(jq -r 'if .body then (.body | fromjson
                 | [(.stopped_reason // empty)] | join(" ")) else "" end' \
          "$TMPFILE" 2>/dev/null || true)
    # ECS task id, when the Lambda got far enough to start a task.
    TASK_ID=$(jq -r 'if .body then (.body | fromjson | .task_id // empty) else empty end' \
          "$TMPFILE" 2>/dev/null || true)
    CLI_ERR=$(tr '\n' ' ' < "${TMPFILE}.err" 2>/dev/null | cut -c1-300)
    rm -f "$TMPFILE" "${TMPFILE}.err"

    printf "  [%3d/%-3d] %-55s" "$LABEL" "$TOTAL" "$IMAGE"

    case "$STATUS" in
      200)
        RESULT="SUCCESS"
        printf "SUCCESS  (%ds) task=%s\n" "$ELAPSED" "${TASK_ID:--}"
        (( PASS++      )) || true
        (( BATCH_PASS++ )) || true
        ;;
      202)
        RESULT="TIMEOUT"
        printf "TIMEOUT  (%ds) task=%s - task did not finish in time\n" "$ELAPSED" "${TASK_ID:--}"
        (( FAIL++      )) || true
        (( BATCH_FAIL++ )) || true
        ;;
      *)
        RESULT="FAILED"
        printf "FAILED   (%ds) task=%s - %s%s%s\n" "$ELAPSED" "${TASK_ID:--}" "$MSG" \
          "${DETAIL:+ [$DETAIL]}" "${CLI_ERR:+ (aws cli: $CLI_ERR)}"
        (( FAIL++      )) || true
        (( BATCH_FAIL++ )) || true
        ;;
    esac

    # Tabs and newlines in the message would break the TSV columns.
    FLAT_MSG=$(printf '%s%s%s' "$MSG" "${DETAIL:+ [$DETAIL]}" "${CLI_ERR:+ (aws cli: $CLI_ERR)}" | tr '\t\n' '  ')
    printf '%s\t%s\t%s\t%s\t%s\n' "$RESULT" "$IMAGE" "${TASK_ID:-}" "$ELAPSED" "$FLAT_MSG" >> "$RESULTS_FILE"

    (( SCANNED++ )) || true
  done

  printf "  Batch %d/%d done: %d passed, %d failed\n" \
    "$BATCH_NUM" "$BATCHES" "$BATCH_PASS" "$BATCH_FAIL"
  print_progress
  echo
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START_TIME ))
MINS=$(( ELAPSED / 60 ))
SECS=$(( ELAPSED % 60 ))

echo "=============================="
echo " Scan complete"
printf " Total:    %d\n" "$TOTAL"
printf " Passed:   %d\n" "$PASS"
printf " Failed:   %d\n" "$FAIL"
[[ $SKIPPED_REPOS -gt 0 ]] && printf " Skipped:  %d repositories could not be read\n" "$SKIPPED_REPOS"
printf " Duration: %dm %ds\n" "$MINS" "$SECS"
$DRY_RUN || printf " Results:  %s\n" "$RESULTS_FILE"
echo "=============================="

[[ $FAIL -gt 0 || $SKIPPED_REPOS -gt 0 ]] && exit 1 || exit 0
