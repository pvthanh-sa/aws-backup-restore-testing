"""RDS restore validator.

Describes the restored DB instance and reports the validation result back to AWS
Backup. Rule is exactly as in the source CFN: DBInstanceStatus == "available",
and ValidationStatus is "SUCCESSFUL"/"FAILED".

Infrastructure errors (e.g. IAM AccessDenied) are reported to AWS Backup as
FAILED + message *before* re-raising, so the restore job shows FAILED with a
reason instead of a silent TIMED_OUT. The stack trace still lands in CloudWatch.
"""

import boto3

rds = boto3.client("rds")
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
        # arn:aws:rds:region:account:db:instance-id -> instance-id
        instance_id = created_arn.split(":")[-1]

        resp = rds.describe_db_instances(DBInstanceIdentifier=instance_id)
        db_status = resp["DBInstances"][0]["DBInstanceStatus"]

        if db_status == "available":
            status = "SUCCESSFUL"
            message = f"DB instance {instance_id} status is '{db_status}'."
        else:
            status = "FAILED"
            message = f"DB instance {instance_id} status is '{db_status}' (expected 'available')."

        _report(restore_job_id, status, message)
        return {"restoreJobId": restore_job_id, "validationStatus": status}

    except Exception as e:
        # Surface infra/runtime errors as a FAILED verdict (not a silent timeout).
        err = f"RDS validator error ({resource_type}): {type(e).__name__}: {e}"
        print(err)
        if restore_job_id:
            try:
                _report(restore_job_id, "FAILED", err)
            except Exception as report_err:
                print(f"Could not report FAILED to AWS Backup: {report_err}")
        raise
