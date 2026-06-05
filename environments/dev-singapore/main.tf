###############################################################################
# PART B — supporting resources (NOT in the original CFN blog).
# Provides a vault + a backup plan + test resources so the restore-testing
# apparatus has recovery points to exercise end-to-end.
###############################################################################

# --- Test network (only when the RDS branch is enabled) -----------------------
module "network" {
  count  = var.enable_rds ? 1 : 0
  source = "../../modules/network"

  name             = "${local.app_name}-vpc"
  vpc_cidr         = var.vpc_cidr
  aws_region       = var.region
  azs_name         = local.az_suffixes
  database_subnets = var.database_subnet_cidrs

  create_database_subnet_group       = true
  database_subnet_group_name         = "${local.app_name}-db-subnet-group"
  create_database_subnet_route_table = true

  # Private-only test DB: no internet path needed.
  create_igw         = false
  enable_nat_gateway = false

  tags = local.tags
}

# --- Test RDS (tagged backup=true so the Part B plan backs it up) -------------
module "rds" {
  count  = var.enable_rds ? 1 : 0
  source = "../../modules/rds"

  app_name          = local.app_name
  db_name           = "${local.app_name}-test"
  vpc_id            = module.network[0].vpc_id
  availability_zone = "${var.region}${local.az_suffixes[0]}"

  db_subnet_group_name = module.network[0].database_subnet_group_name

  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  storage_encrypted = true
  multi_az          = false

  # Lab economics: no replica, no enhanced monitoring/PI, easy teardown.
  skip_final_snapshot          = true
  deletion_protection          = false
  performance_insights_enabled = false
  monitoring_interval          = 0
  create_replica               = false

  # Password auto-generated into Secrets Manager (no secret in tfvars).
  tags = merge(local.tags, { backup = "true" })
}

# --- Test S3 bucket (reused module, extended with force_destroy) --------------
module "test_bucket" {
  count  = var.enable_s3 ? 1 : 0
  source = "../../modules/s3_backend_storage"

  app_name = local.app_name

  # New behavior-preserving variables added to the library module:
  force_destroy             = true  # versioned bucket must be force-emptied on destroy
  create_cors_configuration = false # lab bucket needs no CORS
  create_access_policy      = false # lab bucket needs no pre-signed-URL IAM policy

  # Expire old versions quickly + abort stale MPUs (lab hygiene / cost).
  enable_lifecycle                   = true
  noncurrent_version_expiration_days = 7

  tags = merge(local.tags, { backup = "true" })
}

# Upload >1 object so the S3 validator rule (object_count > 1) passes.
resource "aws_s3_object" "sample" {
  for_each = var.enable_s3 ? {
    "validation/sample-1.txt" = "restore-testing sample object 1"
    "validation/sample-2.txt" = "restore-testing sample object 2"
  } : {}

  bucket  = module.test_bucket[0].bucket_id
  key     = each.key
  content = each.value

  tags = merge(local.tags, { Name = "${local.app_name}-sample" })
}

# --- Backup vault + plan + selection (creates the recovery points) ------------
resource "aws_backup_vault" "practice" {
  name = "${local.app_name}-vault"
  # kms_key_arn omitted -> AWS-managed key (aws/backup).
  tags = merge(local.tags, { Name = "${local.app_name}-vault" })
}

resource "aws_backup_plan" "practice" {
  name = "${local.app_name}-plan"

  rule {
    rule_name         = "daily-practice"
    target_vault_name = aws_backup_vault.practice.name
    schedule          = var.backup_schedule_expression

    lifecycle {
      delete_after = var.backup_delete_after_days
    }
  }

  tags = merge(local.tags, { Name = "${local.app_name}-plan" })
}

# Note: aws_backup_selection has no `tags` argument (not a taggable resource),
# so the house Name/ManagedBy tag convention does not apply here.
resource "aws_backup_selection" "practice" {
  name         = "${local.app_name}-selection"
  plan_id      = aws_backup_plan.practice.id
  iam_role_arn = module.backup_restore_testing.backup_service_role_arn

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "backup"
    value = "true"
  }
}

###############################################################################
# PART A — the restore-testing apparatus (1:1 CFN port, authored module).
###############################################################################
module "backup_restore_testing" {
  source = "../../modules/backup-restore-testing"

  app_name = local.app_name
  tags     = local.tags

  enable_s3  = var.enable_s3
  enable_rds = var.enable_rds

  # Explicit subnet-group wiring (replaces the CFN Lambda subnet-finder).
  rds_subnet_group_name = var.enable_rds ? module.network[0].database_subnet_group_name : ""

  restore_schedule_expression = var.restore_schedule_expression
  start_window_hours          = var.start_window_hours
  validation_window_hours     = var.validation_window_hours
  selection_window_days       = var.selection_window_days
  lambda_log_retention_days   = var.lambda_log_retention_days
}
