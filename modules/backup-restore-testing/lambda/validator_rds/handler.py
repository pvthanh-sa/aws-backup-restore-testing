"""RDS restore validator.

Describes the restored DB instance and reports the validation result back to AWS
Backup. Rule is exactly as in the source CFN: DBInstanceStatus == "available",
and ValidationStatus is "SUCCESSFUL"/"FAILED".
"""

import boto3

rds = boto3.client("rds")
backup = boto3.client("backup")


def lambda_handler(event, context):
    detail = event.get("detail", {})
    restore_job_id = detail.get("restoreJobId")
    resource_type = detail.get("resourceType")
    created_arn = detail.get("createdResourceArn", "")

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

    print(f"restoreJobId={restore_job_id} resourceType={resource_type} {message}")

    backup.put_restore_validation_result(
        RestoreJobId=restore_job_id,
        ValidationStatus=status,
        ValidationStatusMessage=message,
    )

    return {"restoreJobId": restore_job_id, "validationStatus": status}
