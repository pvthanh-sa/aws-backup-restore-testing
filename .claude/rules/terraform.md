---
globs:
  - '**/*.tf'
  - '**/*.tfvars'
  - '**/terraform*'
---
# Terraform Rules

## File Structure
- Module directory: `versions.tf`, `variables.tf`, `main.tf`, `data.tf`, `outputs.tf`, `locals.tf`
- Environment directory: `backend.tf`, `providers.tf`, `main.tf`, `variables.tf`, `terraform.tfvars`, `outputs.tf`, `locals.tf`

## Naming & Tagging
- Resource naming: `${var.app_name}-<resource-type>` (e.g., `${var.app_name}-ecs-task-role`)
- Tag pattern: always use `merge(var.tags, { Name = "${var.app_name}-...", ManagedBy = "Terraform" })`
- Variable naming: `snake_case`, prefix booleans with `create_` or `enable_`

## Code Standards
- Always add `description` to every variable and output
- Always add `validation` blocks to variables with constrained values
- Use `for_each` over `count` unless ordering matters
- Use `dynamic` blocks for conditional nested blocks
- Use `locals` for computed values and complex expressions
- Use `templatefile()` for JSON/YAML templates, never inline complex `jsonencode()`

## Provider & Version
- Pin provider versions with `>=` constraints (e.g., `>= 5.0.0`)
- Set `required_version` for Terraform core
- Dual-region pattern: default region + `us-east-1` alias for CloudFront/ACM

## State Management
- Always use S3 backend with `use_lockfile = true`
- Separate state file per environment (`key = "<env>/terraform.tfstate"`)
- Never use local state for production or shared environments

## Lifecycle
- Use `create_before_destroy = true` for zero-downtime replacements
- Use `ignore_changes` for fields managed by external processes (e.g., CodeDeploy)

## Security
- Never hardcode AWS account IDs, regions, or credentials in `.tf` files
- Never store secrets in `.tfvars` — use Secrets Manager or SSM
- Use `sensitive = true` for outputs containing secrets
- Use `data.aws_iam_policy_document` for IAM policies (not inline JSON)

## Validation
- Run after every change: `terraform fmt` → `terraform validate` → `tflint` → `checkov`
- Never run `terraform apply -auto-approve` in production
- Always use `terraform plan -out=tfplan` then `terraform apply tfplan`
