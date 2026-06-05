data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

# Lambda source zips. No aws_db_subnet_groups data source exists in the AWS
# provider, so the RDS subnet group is wired explicitly via var.rds_subnet_group_name.

data "archive_file" "coordinator" {
  type        = "zip"
  source_file = "${path.module}/lambda/coordinator/handler.py"
  output_path = "${path.module}/build/coordinator.zip"
}

data "archive_file" "validator_s3" {
  count       = var.enable_s3 ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/validator_s3/handler.py"
  output_path = "${path.module}/build/validator_s3.zip"
}

data "archive_file" "validator_rds" {
  count       = var.enable_rds ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/validator_rds/handler.py"
  output_path = "${path.module}/build/validator_rds.zip"
}
