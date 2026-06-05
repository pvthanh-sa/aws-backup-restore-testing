variable "region" {
  description = "AWS region for the lab."
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "region must be a valid AWS region identifier, e.g. ap-southeast-1."
  }
}

variable "profile" {
  description = "AWS CLI profile (from ~/.aws/credentials) used to authenticate."
  type        = string
}

variable "environment" {
  description = "Environment name (used as a resource-name prefix)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "app_name" {
  description = "Application name (combined with environment for the resource prefix)."
  type        = string
  default     = "restore-lab"
}

variable "enable_s3" {
  description = "Enable the S3 restore-testing selection + S3 validator + test bucket."
  type        = bool
  default     = true
}

variable "enable_rds" {
  description = "Enable the RDS restore-testing selection + RDS validator + test VPC/RDS."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "CIDR block for the test VPC (only used when enable_rds = true)."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, e.g. 10.20.0.0/16."
  }
}

variable "database_subnet_cidrs" {
  description = "Two database subnet CIDRs across two AZs for the test RDS."
  type        = list(string)
  default     = ["10.20.101.0/24", "10.20.102.0/24"]

  validation {
    condition     = length(var.database_subnet_cidrs) >= 2
    error_message = "Provide at least two database subnet CIDRs (RDS needs >= 2 AZs)."
  }

  validation {
    condition     = alltrue([for c in var.database_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "Each database_subnet_cidrs entry must be a valid IPv4 CIDR block."
  }
}

variable "rds_engine_version" {
  description = "PostgreSQL engine version for the test RDS (must exist in the target region; 17.2 was removed)."
  type        = string
  default     = "17.6"
}

variable "rds_instance_class" {
  description = "Instance class for the test RDS instance (Graviton t4g is cheapest for the lab)."
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = contains(["db.t4g.micro", "db.t4g.small", "db.t3.micro", "db.t3.small"], var.rds_instance_class)
    error_message = "rds_instance_class must be one of: db.t4g.micro, db.t4g.small, db.t3.micro, db.t3.small."
  }
}

variable "restore_schedule_expression" {
  description = "Schedule for the restore-testing plan (passed to the module)."
  type        = string
  default     = "cron(0 22 ? * * *)"

  validation {
    condition     = can(regex("^(cron|rate)\\(", var.restore_schedule_expression))
    error_message = "restore_schedule_expression must start with cron( or rate(."
  }
}

variable "start_window_hours" {
  description = "Restore-testing job start window (hours)."
  type        = number
  default     = 4
}

variable "validation_window_hours" {
  description = "Restore-testing validation window (hours)."
  type        = number
  default     = 4
}

variable "selection_window_days" {
  description = "Recovery-point look-back window (days)."
  type        = number
  default     = 7
}

variable "lambda_log_retention_days" {
  description = "CloudWatch Logs retention for the Lambda log groups."
  type        = number
  default     = 7
}

variable "backup_schedule_expression" {
  description = "Schedule for the Part B backup plan that creates recovery points."
  type        = string
  default     = "cron(0 1 * * ? *)"

  validation {
    condition     = can(regex("^(cron|rate)\\(", var.backup_schedule_expression))
    error_message = "backup_schedule_expression must start with cron( or rate(."
  }
}

variable "backup_delete_after_days" {
  description = "Lifecycle delete_after (days) for recovery points in the practice vault."
  type        = number
  default     = 2
}
