###############################################################################
# IAM — trust policies (all policies via data.aws_iam_policy_document)
###############################################################################

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

###############################################################################
# IAM — Backup service role (CFN: BackupServiceRole)
###############################################################################

resource "aws_iam_role" "backup_service" {
  name               = "${var.app_name}-backup-service-role"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
  tags               = merge(local.common_tags, { Name = "${var.app_name}-backup-service-role" })
}

resource "aws_iam_role_policy_attachment" "backup_service" {
  for_each   = local.backup_service_managed_policies
  role       = aws_iam_role.backup_service.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

###############################################################################
# IAM — Coordinator Lambda role (CFN: LambdaCoordinatorRole)
###############################################################################

resource "aws_iam_role" "coordinator" {
  name               = "${var.app_name}-coordinator-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = merge(local.common_tags, { Name = "${var.app_name}-coordinator-role" })
}

resource "aws_iam_role_policy_attachment" "coordinator_basic" {
  role       = aws_iam_role.coordinator.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Least-privilege: scope InvokeFunction to the enabled validator ARNs (CFN used "*").
data "aws_iam_policy_document" "coordinator_invoke" {
  count = local.create_coordinator_inline ? 1 : 0

  statement {
    sid       = "InvokeValidators"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = local.validator_function_arns
  }
}

resource "aws_iam_role_policy" "coordinator_invoke" {
  count  = local.create_coordinator_inline ? 1 : 0
  name   = "${var.app_name}-coordinator-invoke"
  role   = aws_iam_role.coordinator.id
  policy = data.aws_iam_policy_document.coordinator_invoke[0].json
}

###############################################################################
# IAM — S3 validator Lambda role (CFN: LambdaS3RestoreRole)
###############################################################################

resource "aws_iam_role" "validator_s3" {
  count              = var.enable_s3 ? 1 : 0
  name               = "${var.app_name}-validator-s3-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = merge(local.common_tags, { Name = "${var.app_name}-validator-s3-role" })
}

resource "aws_iam_role_policy_attachment" "validator_s3_basic" {
  count      = var.enable_s3 ? 1 : 0
  role       = aws_iam_role.validator_s3[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "validator_s3" {
  count = var.enable_s3 ? 1 : 0

  statement {
    sid    = "S3Read"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetObject",
    ]
    # Scoped to restored buckets (default: AWS Backup restore-test naming).
    # Widen via var.s3_restore_bucket_name_patterns if restores use other names.
    resources = concat(
      [for p in var.s3_restore_bucket_name_patterns : "arn:${local.partition}:s3:::${p}"],
      [for p in var.s3_restore_bucket_name_patterns : "arn:${local.partition}:s3:::${p}/*"],
    )
  }

  statement {
    sid       = "PutValidationResult"
    effect    = "Allow"
    actions   = ["backup:PutRestoreValidationResult"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "validator_s3" {
  count  = var.enable_s3 ? 1 : 0
  name   = "${var.app_name}-validator-s3"
  role   = aws_iam_role.validator_s3[0].id
  policy = data.aws_iam_policy_document.validator_s3[0].json
}

###############################################################################
# IAM — RDS validator Lambda role (CFN: LambdaRDSRestoreRole)
###############################################################################

resource "aws_iam_role" "validator_rds" {
  count              = var.enable_rds ? 1 : 0
  name               = "${var.app_name}-validator-rds-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = merge(local.common_tags, { Name = "${var.app_name}-validator-rds-role" })
}

resource "aws_iam_role_policy_attachment" "validator_rds_basic" {
  count      = var.enable_rds ? 1 : 0
  role       = aws_iam_role.validator_rds[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "validator_rds" {
  count = var.enable_rds ? 1 : 0

  statement {
    sid       = "RdsDescribe"
    effect    = "Allow"
    actions   = ["rds:DescribeDBInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "PutValidationResult"
    effect    = "Allow"
    actions   = ["backup:PutRestoreValidationResult"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "validator_rds" {
  count  = var.enable_rds ? 1 : 0
  name   = "${var.app_name}-validator-rds"
  role   = aws_iam_role.validator_rds[0].id
  policy = data.aws_iam_policy_document.validator_rds[0].json
}

###############################################################################
# Restore Testing Plan (CFN: BackupRestoreTestingPlan)
###############################################################################

resource "aws_backup_restore_testing_plan" "this" {
  name                         = var.restore_testing_plan_name
  schedule_expression          = var.restore_schedule_expression
  schedule_expression_timezone = "UTC"
  start_window_hours           = var.start_window_hours

  recovery_point_selection {
    algorithm             = "LATEST_WITHIN_WINDOW"
    include_vaults        = ["*"]
    recovery_point_types  = ["SNAPSHOT"]
    selection_window_days = var.selection_window_days
  }

  tags = merge(local.common_tags, { Name = "${var.app_name}-restore-testing-plan" })
}

###############################################################################
# Restore Testing Selections (CFN: BackupRestoreTestingSelection*)
###############################################################################

resource "aws_backup_restore_testing_selection" "s3" {
  count                     = var.enable_s3 ? 1 : 0
  name                      = "RestoreTestingSelectionS3"
  restore_testing_plan_name = aws_backup_restore_testing_plan.this.name
  protected_resource_type   = "S3"
  iam_role_arn              = aws_iam_role.backup_service.arn
  protected_resource_arns   = ["*"]
  validation_window_hours   = var.validation_window_hours
}

resource "aws_backup_restore_testing_selection" "rds" {
  count                     = var.enable_rds ? 1 : 0
  name                      = "RestoreTestingSelectionRDS"
  restore_testing_plan_name = aws_backup_restore_testing_plan.this.name
  protected_resource_type   = "RDS"
  iam_role_arn              = aws_iam_role.backup_service.arn
  protected_resource_arns   = ["*"]
  validation_window_hours   = var.validation_window_hours

  # camelCase key, exactly as in the CFN RestoreMetadataOverrides.
  restore_metadata_overrides = {
    dbSubnetGroupName = local.rds_subnet_group
  }
}

###############################################################################
# CloudWatch Log Groups (explicit, with retention; Lambdas depend_on these)
###############################################################################

resource "aws_cloudwatch_log_group" "coordinator" {
  name              = "/aws/lambda/${local.coordinator_function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = merge(local.common_tags, { Name = "${var.app_name}-coordinator-logs" })
}

resource "aws_cloudwatch_log_group" "validator_s3" {
  count             = var.enable_s3 ? 1 : 0
  name              = "/aws/lambda/${local.validator_s3_function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = merge(local.common_tags, { Name = "${var.app_name}-validator-s3-logs" })
}

resource "aws_cloudwatch_log_group" "validator_rds" {
  count             = var.enable_rds ? 1 : 0
  name              = "/aws/lambda/${local.validator_rds_function_name}"
  retention_in_days = var.lambda_log_retention_days
  tags              = merge(local.common_tags, { Name = "${var.app_name}-validator-rds-logs" })
}

###############################################################################
# Lambda Functions (python3.12, 60s, 128MB)
###############################################################################

resource "aws_lambda_function" "coordinator" {
  function_name    = local.coordinator_function_name
  role             = aws_iam_role.coordinator.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 128
  filename         = data.archive_file.coordinator.output_path
  source_code_hash = data.archive_file.coordinator.output_base64sha256

  environment {
    variables = {
      VALIDATOR_S3  = var.enable_s3 ? local.validator_s3_function_name : ""
      VALIDATOR_RDS = var.enable_rds ? local.validator_rds_function_name : ""
    }
  }

  tags       = merge(local.common_tags, { Name = "${var.app_name}-coordinator" })
  depends_on = [aws_cloudwatch_log_group.coordinator]
}

resource "aws_lambda_function" "validator_s3" {
  count            = var.enable_s3 ? 1 : 0
  function_name    = local.validator_s3_function_name
  role             = aws_iam_role.validator_s3[0].arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 128
  filename         = data.archive_file.validator_s3[0].output_path
  source_code_hash = data.archive_file.validator_s3[0].output_base64sha256

  tags       = merge(local.common_tags, { Name = "${var.app_name}-validator-s3" })
  depends_on = [aws_cloudwatch_log_group.validator_s3]
}

resource "aws_lambda_function" "validator_rds" {
  count            = var.enable_rds ? 1 : 0
  function_name    = local.validator_rds_function_name
  role             = aws_iam_role.validator_rds[0].arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 128
  filename         = data.archive_file.validator_rds[0].output_path
  source_code_hash = data.archive_file.validator_rds[0].output_base64sha256

  tags       = merge(local.common_tags, { Name = "${var.app_name}-validator-rds" })
  depends_on = [aws_cloudwatch_log_group.validator_rds]
}

###############################################################################
# EventBridge — fire coordinator when a restore-testing job COMPLETED
###############################################################################

resource "aws_cloudwatch_event_rule" "restore_completed" {
  name        = "Backup_restore_testing"
  description = "Trigger restore-validation coordinator on restore-testing job completion."

  event_pattern = jsonencode({
    source      = ["aws.backup"]
    detail-type = ["Restore Job State Change"]
    detail = {
      status                = ["COMPLETED"]
      restoreTestingPlanArn = [{ prefix = aws_backup_restore_testing_plan.this.arn }]
    }
  })

  tags = merge(local.common_tags, { Name = "${var.app_name}-restore-completed-rule" })
}

resource "aws_cloudwatch_event_target" "coordinator" {
  rule      = aws_cloudwatch_event_rule.restore_completed.name
  target_id = "RestoreValidationCoordinator"
  arn       = aws_lambda_function.coordinator.arn
}

resource "aws_lambda_permission" "eventbridge_invoke_coordinator" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.coordinator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.restore_completed.arn
}
