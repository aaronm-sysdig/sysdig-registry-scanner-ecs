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
#   --max-age-days N   only scan images pushed within this many days (default: 365)
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
ACCOUNT_ID="123456789012"
CLUSTER="Sysdig-Fargate-Test-Cluster"
SUBNET="subnet-xxxxxxxxx"
SECURITY_GROUP="sg-xxxxxxxxx"
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

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
CUTOFF=$(date -u -v-${MAX_AGE_DAYS}d +%Y-%m-%dT%H:%M:%S 2>/dev/null \
      || date -u -d "${MAX_AGE_DAYS} days ago" +%Y-%m-%dT%H:%M:%S)

# ---------------------------------------------------------------------------
# Discover images
# ---------------------------------------------------------------------------
echo "Discovering ECR repositories in ${REGION}..."

IMAGES=()

while IFS= read -r REPO; do
  [[ -z "$REPO" ]] && continue
  # Use JSON output + jq to get one tag per line (text output is tab-separated)
  while IFS= read -r TAG; do
    [[ -z "$TAG" || "$TAG" == "null" ]] && continue
    IMAGES+=("${REPO}:${TAG}")
  done < <(aws ecr describe-images \
    --repository-name "$REPO" \
    --region "$REGION" \
    --query "imageDetails[?imagePushedAt >= '${CUTOFF}' && length(imageTags) > \`0\`].imageTags[0]" \
    --output json 2>/dev/null | jq -r '.[]' 2>/dev/null || true)
done < <(aws ecr describe-repositories --region "$REGION" \
  --query 'repositories[*].repositoryName' --output text \
  | tr '\t' '\n')

TOTAL=${#IMAGES[@]}
REPO_COUNT=$(aws ecr describe-repositories --region "$REGION" \
  --query 'length(repositories)' --output text 2>/dev/null)

if [[ $TOTAL -eq 0 ]]; then
  echo "No tagged images found pushed within the last ${MAX_AGE_DAYS} days."
  exit 0
fi

BATCHES=$(( (TOTAL + BATCH_SIZE - 1) / BATCH_SIZE ))

echo "Found ${TOTAL} images across ${REPO_COUNT} repositories"
echo "Batch size: ${BATCH_SIZE} | Batches: ${BATCHES} | Max age: ${MAX_AGE_DAYS} days"
$DRY_RUN && echo "(dry run - Lambda will not be invoked)"
echo

# ---------------------------------------------------------------------------
# Scan in batches
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SCANNED=0
START_TIME=$(date +%s)

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

  # Per-image tracking for this batch
  declare -a BATCH_IMAGES=()
  declare -A BATCH_PIDS=()
  declare -A BATCH_FILES=()
  declare -A BATCH_TIMES=()

  for (( I=0; I<COUNT; I++ )); do
    IMAGE="${IMAGES[$(( OFFSET + I ))]}"
    LABEL=$(( OFFSET + I + 1 ))
    BATCH_IMAGES+=("$IMAGE")
    TMPFILE=$(mktemp /tmp/scan-XXXXXX)
    BATCH_FILES["$IMAGE"]="$TMPFILE"
    BATCH_TIMES["$IMAGE"]=$(date +%s)

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
      "$TMPFILE" >/dev/null 2>&1 &

    BATCH_PIDS["$IMAGE"]=$!
    echo "launched"
  done

  $DRY_RUN && { echo; continue; }

  echo "  Waiting for batch ${BATCH_NUM}/${BATCHES}..."
  wait

  BATCH_PASS=0
  BATCH_FAIL=0

  for IMAGE in "${BATCH_IMAGES[@]}"; do
    TMPFILE="${BATCH_FILES[$IMAGE]}"
    LABEL=$(( OFFSET + $(( $(printf '%s\n' "${BATCH_IMAGES[@]}" | grep -n "^${IMAGE}$" | cut -d: -f1) - 1 )) + 1 ))
    ELAPSED=$(( $(date +%s) - ${BATCH_TIMES[$IMAGE]} ))
    STATUS=$(jq -r '.statusCode' "$TMPFILE" 2>/dev/null || echo "error")
    rm -f "$TMPFILE"

    printf "  [%3d/%-3d] %-55s" "$LABEL" "$TOTAL" "$IMAGE"

    case "$STATUS" in
      200)
        printf "SUCCESS  (%ds)\n" "$ELAPSED"
        (( PASS++      )) || true
        (( BATCH_PASS++ )) || true
        ;;
      202)
        printf "TIMEOUT  (%ds) - task did not finish in time\n" "$ELAPSED"
        (( FAIL++      )) || true
        (( BATCH_FAIL++ )) || true
        ;;
      *)
        MSG=$(jq -r '.body | fromjson | .message // .error // "unknown"' "${BATCH_FILES[$IMAGE]}" 2>/dev/null || echo "unknown")
        printf "FAILED   (%ds) - %s\n" "$ELAPSED" "$MSG"
        (( FAIL++      )) || true
        (( BATCH_FAIL++ )) || true
        ;;
    esac

    (( SCANNED++ )) || true
  done

  printf "  Batch %d/%d done: %d passed, %d failed\n" \
    "$BATCH_NUM" "$BATCHES" "$BATCH_PASS" "$BATCH_FAIL"
  print_progress
  echo

  unset BATCH_IMAGES BATCH_PIDS BATCH_FILES BATCH_TIMES
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
printf " Duration: %dm %ds\n" "$MINS" "$SECS"
echo "=============================="

[[ $FAIL -gt 0 ]] && exit 1 || exit 0
