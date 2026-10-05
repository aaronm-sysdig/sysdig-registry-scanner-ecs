# TODO

## Surface scan failure reasons in manual and bulk scans

When an ECS scan task fails, `scan-all.sh` and `test.sh` only show a generic
message such as "Scan failed for X with exit code 1". The real cause (for
example an HTTP error from the registry or the Sysdig API) is only visible in
the `/ecs/Sysdig-Registry-Scanner` CloudWatch logs, which makes a run-all scan
hard to triage.

Plan, cheapest first:

1. **Return more of what ECS already knows.** In `lambda/run-registry-scan`,
   add `stopCode` and the container-level `reason` from `describe_tasks`
   (e.g. `CannotPullContainerError`, `ResourceInitializationError`) to the
   failure response, next to `stopped_reason`. No new IAM permissions needed.
2. **Capture the scanner's own error.** On failure, have the Lambda read the
   last N lines of the task's log stream (stream is
   `ecs/registry-scanner/<task_id>`) and return the error lines, including any
   HTTP status, as an `error_detail` field. Needs `logs:GetLogEvents` (or
   `logs:FilterLogEvents`) on `/ecs/Sysdig-Registry-Scanner` added to
   `iam/lambda-policy.json`. Note logs can lag the task stop by a few seconds.
3. **Show it in the scripts.** Update `scan-all.sh` (and `test.sh`) to print
   `stopped_reason` and `error_detail` per failed image, and write failures to
   a summary file (image, exit code, reason) at the end of the run so they can
   be reviewed or retried.
