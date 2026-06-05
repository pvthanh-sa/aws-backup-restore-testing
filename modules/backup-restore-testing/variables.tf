variable "app_name" {
  description = "Prefix for all resource names created by this module."
  type        = string
  default     = "restore-lab"
}

variable "tags" {
  description = "Tags merged into common_tags and applied to all resources."
  type        = map(string)
  default     = {}
}

variable "restore_testing_plan_name" {
  description = "Name of the AWS Backup restore-testing plan (CFN: RestoreTestingPlanName)."
  type        = string
  default     = "DailyRestorePlan"

  validation {
    condition     = can(regex("^[A-Za-z0-9_]+$", var.restore_testing_plan_name))
    error_message = "restore_testing_plan_name must contain only letters, numbers, and underscores."
  }
}

variable "restore_schedule_expression" {
  description = "Schedule for the restore-testing plan (CFN: ScheduleExpression). Default 10PM UTC daily."
  type        = string
  default     = "cron(0 22 ? * * *)"
}

variable "start_window_hours" {
  description = "Hours the restore-testing job may wait to start (CFN: StartWindowHours)."
  type        = number
  default     = 4

  validation {
    condition     = var.start_window_hours >= 1 && var.start_window_hours <= 168
    error_message = "start_window_hours must be between 1 and 168."
  }
}

variable "validation_window_hours" {
  description = "Hours the restored resource is kept for validation (CFN: ValidationWindowHours)."
  type        = number
  default     = 4

  validation {
    condition     = var.validation_window_hours >= 1 && var.validation_window_hours <= 168
    error_message = "validation_window_hours must be between 1 and 168."
  }
}

variable "selection_window_days" {
  description = "Look-back window for eligible recovery points (CFN: SelectionWindowDays)."
  type        = number
  default     = 7

  validation {
    condition     = var.selection_window_days >= 1 && var.selection_window_days <= 365
    error_message = "selection_window_days must be between 1 and 365."
  }
}

variable "enable_s3" {
  description = "Enable the S3 restore-testing selection + S3 validator Lambda."
  type        = bool
  default     = true
}

variable "enable_rds" {
  description = "Enable the RDS restore-testing selection + RDS validator Lambda."
  type        = bool
  default     = true
}

variable "rds_subnet_group_name" {
  description = "Name of the DB subnet group used for restore-testing RDS (dbSubnetGroupName override). Required when enable_rds = true. The caller passes the name of an existing DB subnet group (no Lambda subnet-finder)."
  type        = string
  default     = ""

  validation {
    condition     = var.enable_rds == false || length(trimspace(var.rds_subnet_group_name)) > 0
    error_message = "rds_subnet_group_name must be non-empty when enable_rds = true."
  }
}

variable "s3_restore_bucket_name_patterns" {
  description = "S3 bucket name patterns the S3 validator Lambda is allowed to read (the buckets AWS Backup creates during restore testing). Scopes the validator IAM policy; widen if your restores use different names."
  type        = list(string)
  default     = ["aws-backup-restore-*"]
}

variable "lambda_log_retention_days" {
  description = "CloudWatch Logs retention (days) for the Lambda log groups."
  type        = number
  default     = 7

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.lambda_log_retention_days
    )
    error_message = "lambda_log_retention_days must be a valid CloudWatch Logs retention value."
  }
}
