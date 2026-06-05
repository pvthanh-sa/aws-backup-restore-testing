output "backup_service_role_arn" {
  description = "ARN of the AWS Backup service role."
  value       = module.backup_restore_testing.backup_service_role_arn
}

output "restore_testing_plan_name" {
  description = "Name of the restore-testing plan."
  value       = module.backup_restore_testing.restore_testing_plan_name
}

output "restore_testing_plan_arn" {
  description = "ARN of the restore-testing plan."
  value       = module.backup_restore_testing.restore_testing_plan_arn
}

output "coordinator_function_name" {
  description = "Name of the restore-validation coordinator Lambda."
  value       = module.backup_restore_testing.coordinator_function_name
}

output "validator_s3_function_name" {
  description = "Name of the S3 validator Lambda (null when enable_s3 = false)."
  value       = module.backup_restore_testing.validator_s3_function_name
}

output "validator_rds_function_name" {
  description = "Name of the RDS validator Lambda (null when enable_rds = false)."
  value       = module.backup_restore_testing.validator_rds_function_name
}

output "practice_vault_name" {
  description = "Name of the practice backup vault."
  value       = aws_backup_vault.practice.name
}

output "test_bucket_id" {
  description = "Name of the test S3 bucket (null when enable_s3 = false)."
  value       = try(module.test_bucket[0].bucket_id, null)
}

output "test_rds_instance_id" {
  description = "Identifier of the test RDS instance (null when enable_rds = false)."
  value       = try(module.rds[0].db_instance_identifier, null)
}

output "test_rds_db_subnet_group_name" {
  description = "DB subnet group name wired into the RDS restore-testing selection."
  value       = try(module.network[0].database_subnet_group_name, null)
}
