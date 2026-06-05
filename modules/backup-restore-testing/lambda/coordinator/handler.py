"""Restore-validation coordinator.

Triggered by EventBridge when a restore-testing job reaches COMPLETED. Maps the
restored resourceType to the matching validator Lambda and invokes it
SYNCHRONOUSLY (RequestResponse), exactly as the source CFN template did.
"""

import json
import os

import boto3

lambda_client = boto3.client("lambda")

# resourceType -> validator function name (empty string when that branch is off).
VALIDATOR_MAP = {
    "S3": os.environ.get("VALIDATOR_S3", ""),
    "RDS": os.environ.get("VALIDATOR_RDS", ""),
}


def lambda_handler(event, context):
    detail = event.get("detail", {})
    resource_type = detail.get("resourceType")

    target = VALIDATOR_MAP.get(resource_type)
    if not target:
        # Unknown / disabled resourceType -> fail loudly (matches CFN).
        raise ValueError(f"Unsupported resourceType: {resource_type!r}")

    response = lambda_client.invoke(
        FunctionName=target,
        InvocationType="RequestResponse",  # synchronous — do NOT use "Event"
        Payload=json.dumps(event).encode("utf-8"),
    )

    payload = response["Payload"].read().decode("utf-8")
    print(f"Validator {target} returned HTTP {response['StatusCode']}: {payload}")

    return {
        "statusCode": response["StatusCode"],
        "validator": target,
        "payload": payload,
    }
