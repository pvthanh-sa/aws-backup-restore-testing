locals {
  common_tags = merge(var.tags, { ManagedBy = "Terraform" })

  # Explicit wiring instead of a Lambda subnet-finder (see data.tf / spec §2).
  rds_subnet_group = var.rds_subnet_group_name

  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  # Lambda function names kept exactly as in the CFN template.
  coordinator_function_name   = "RestoreValidationCoordinator"
  validator_s3_function_name  = "S3RestoreValidation"
  validator_rds_function_name = "RDSRestoreValidation"

  # Managed policies attached to the backup service role (spec §3.1).
  backup_service_managed_policies = {
    backup   = "service-role/AWSBackupServiceRolePolicyForBackup"
    restores = "service-role/AWSBackupServiceRolePolicyForRestores"
    s3backup = "AWSBackupServiceRolePolicyForS3Backup"
    s3restre = "AWSBackupServiceRolePolicyForS3Restore"
  }

  # Enabled validator function ARNs — used to scope the coordinator's
  # lambda:InvokeFunction (least-privilege; CFN used "*").
  validator_function_arns = compact([
    var.enable_s3 ? "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.validator_s3_function_name}" : "",
    var.enable_rds ? "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.validator_rds_function_name}" : "",
  ])

  create_coordinator_inline = var.enable_s3 || var.enable_rds
}
