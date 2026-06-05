"""S3 restore validator.

Lists objects in the restored bucket and reports the validation result back to
AWS Backup. Rule is exactly as in the source CFN: object_count > 1 (NOT >= 1),
and ValidationStatus is "SUCCESSFUL"/"FAILED" (NOT "SUCCESS").
"""

import boto3

s3 = boto3.client("s3")
backup = boto3.client("backup")


def lambda_handler(event, context):
    detail = event.get("detail", {})
    restore_job_id = detail.get("restoreJobId")
    resource_type = detail.get("resourceType")
    created_arn = detail.get("createdResourceArn", "")

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

    print(f"restoreJobId={restore_job_id} resourceType={resource_type} {message}")

    backup.put_restore_validation_result(
        RestoreJobId=restore_job_id,
        ValidationStatus=status,
        ValidationStatusMessage=message,
    )

    return {"restoreJobId": restore_job_id, "validationStatus": status}
