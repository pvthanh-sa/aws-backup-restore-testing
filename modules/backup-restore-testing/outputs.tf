output "backup_service_role_arn" {
  description = "ARN of the AWS Backup service role (used by restore-testing selections and Part B backup selection)."
  value       = aws_iam_role.backup_service.arn
}

output "restore_testing_plan_name" {
  description = "Name of the restore-testing plan."
  value       = aws_backup_restore_testing_plan.this.name
}

output "restore_testing_plan_arn" {
  description = "ARN of the restore-testing plan."
  value       = aws_backup_restore_testing_plan.this.arn
}

output "coordinator_function_name" {
  description = "Name of the restore-validation coordinator Lambda."
  value       = aws_lambda_function.coordinator.function_name
}

output "validator_s3_function_name" {
  description = "Name of the S3 validator Lambda (null when enable_s3 = false)."
  value       = try(aws_lambda_function.validator_s3[0].function_name, null)
}

output "validator_rds_function_name" {
  description = "Name of the RDS validator Lambda (null when enable_rds = false)."
  value       = try(aws_lambda_function.validator_rds[0].function_name, null)
}
