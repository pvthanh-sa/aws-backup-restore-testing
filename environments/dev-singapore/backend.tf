# Remote S3 state for this lab. The account-specific values (bucket name embeds
# the AWS account ID, region, profile) live in backend-dev.hcl, which is
# gitignored so the account ID is never committed. Initialize with:
#   terraform init -backend-config=backend-dev.hcl
terraform {
  backend "s3" {
    key          = "dev-singapore/terraform.tfstate"
    use_lockfile = true
  }
}
