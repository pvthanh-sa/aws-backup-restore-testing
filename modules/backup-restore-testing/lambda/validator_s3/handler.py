"""S3 restore validator.

Lists objects in the restored bucket and reports the validation result back to
AWS Backup. Rule is exactly as in the source CFN: object_count > 1 (NOT >= 1),
and ValidationStatus is "SUCCESSFUL"/"FAILED" (NOT "SUCCESS").

Infrastructure errors (e.g. IAM AccessDenied) are reported to AWS Backup as
FAILED + message *before* re-raising, so the restore job shows FAILED with a
reason instead of a silent TIMED_OUT. The stack trace still lands in CloudWatch.
"""

import boto3

s3 = boto3.client("s3")
backup = boto3.client("backup")

# AWS Backup ValidationStatusMessage has a length limit; keep well under it.
_MSG_MAX = 500


def _report(restore_job_id, status, message):
    print(f"restoreJobId={restore_job_id} validationStatus={status} {message}")
    backup.put_restore_validation_result(
        RestoreJobId=restore_job_id,
        ValidationStatus=status,
        ValidationStatusMessage=message[:_MSG_MAX],
    )


def lambda_handler(event, context):
    detail = event.get("detail", {})
    restore_job_id = detail.get("restoreJobId")
    resource_type = detail.get("resourceType")
    created_arn = detail.get("createdResourceArn", "")

    try:
        # arn:aws:s3:::bucket-name[/key] -> bucket-name
        bucket = created_arn.split(":::")[-1].split("/")[0]

        resp = s3.list_objects_v2(Bucket=bucket)
        object_count = resp.get("KeyCount", 0)

        if object_count > 1:
            status = "SUCCESSFUL"
            message = f"Bucket {bucket} has {object_count} objects (> 1)."
        else:
            status = "FAILED"
            message = f"Bucket {bucket} has {object_count} objects (expected > 1)."

        _report(restore_job_id, status, message)
        return {"restoreJobId": restore_job_id, "validationStatus": status}

    except Exception as e:
        # Surface infra/runtime errors as a FAILED verdict (not a silent timeout).
        err = f"S3 validator error ({resource_type}): {type(e).__name__}: {e}"
        print(err)
        if restore_job_id:
            try:
                _report(restore_job_id, "FAILED", err)
            except Exception as report_err:
                print(f"Could not report FAILED to AWS Backup: {report_err}")
        raise
