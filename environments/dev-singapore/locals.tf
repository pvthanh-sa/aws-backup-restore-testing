locals {
  tags = {
    Project     = "aws-backup-restore-testing"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  app_name = "${var.environment}-${var.app_name}"

  # Two database subnets across two AZs (suffixes wired into the network module).
  az_suffixes = ["a", "b"]
}
