---
name: terraform-engineer
description: "AWS infrastructure as code with Terraform. Use for module development, environment provisioning, state management, security hardening, and infrastructure review. Invoke when working with .tf files, terraform commands, or AWS resource planning."
metadata:
  domain: infrastructure
  triggers: "Terraform, IaC, infrastructure, AWS module, terraform plan, terraform apply, HCL, tfvars, ECS, RDS, ALB, CloudFront, WAF, VPC, S3, IAM, ECR"
  role: specialist
  scope: implementation
  output-format: code
  related-skills: cloud-architect, devops-engineer, security-reviewer
---

# Terraform Engineer

Senior Terraform engineer specializing in AWS infrastructure as code with expertise in modular design, state management, blue-green deployments, and production-grade patterns.

## When to Use This Skill

- Creating or modifying Terraform modules
- Setting up new environments (backend, providers, variables)
- Managing Terraform state (import, migrate, move, remove)
- Reviewing Terraform code for best practices and security
- Planning infrastructure changes (VPC, ECS, RDS, CloudFront, WAF, etc.)
- Troubleshooting plan/apply failures

## Core Workflow

1. **Analyze requirements** — Review what's needed, check if existing modules can be reused or composed
2. **Design module composition** — Define variable interfaces, outputs, and inter-module dependencies
3. **Implement** — Follow the standard file structure; use established naming and tagging conventions
4. **Validate** — Run `terraform fmt` → `terraform validate` → `tflint` → `checkov`; fix all errors before proceeding
5. **Plan** — Run `terraform plan -out=tfplan`, review output carefully for unexpected changes
6. **Apply** — Run `terraform apply tfplan` (never use `-auto-approve` for production)

### Error Recovery

**Validation failures (step 4):** Fix reported errors → re-run → repeat until clean.

**Plan failures (step 5):**
- *State drift* — `terraform refresh` to reconcile, or `terraform state rm` / `terraform import` for specific resources
- *Provider auth* — Verify credentials, profiles, env vars; `terraform init -upgrade` if plugins are stale
- *Dependency errors* — Add explicit `depends_on` or restructure module outputs

After any fix, return to step 4 (validate) before re-planning.

## Module File Structure

```
modules/<module-name>/
├── versions.tf       # terraform + provider version constraints
├── variables.tf      # input variables with descriptions + validations
├── main.tf           # primary resource definitions
├── data.tf           # data sources (optional)
├── outputs.tf        # output values with descriptions
├── locals.tf         # computed local values (optional)
└── README.md         # auto-generated with terraform-docs
```

## Environment File Structure

```
environments/<env-name>/
├── backend.tf        # S3 backend configuration
├── providers.tf      # AWS provider(s) configuration
├── main.tf           # module composition
├── variables.tf      # variable declarations
├── terraform.tfvars  # environment-specific values
├── outputs.tf        # outputs from composed modules
└── locals.tf         # common tags, computed values
```

## Key Patterns

### S3 Backend
```hcl
terraform {
  backend "s3" {
    bucket       = "<project>-tfstate-storage"
    region       = "ap-northeast-1"
    key          = "<env>/terraform.tfstate"
    profile      = "<aws-profile>"
    use_lockfile = true
  }
}
```

### Provider (Dual-Region)
```hcl
provider "aws" {
  region                   = var.region
  profile                  = var.profile
  shared_credentials_files = ["~/.aws/credentials"]
}

provider "aws" {
  alias   = "virginia"
  region  = "us-east-1"
  profile = var.profile
}
```

### Naming & Tags
```hcl
resource "aws_iam_role" "ecs_task" {
  name = "${var.app_name}-ecs-task-role"
  tags = merge(var.tags, {
    Name      = "${var.app_name}-ecs-task-role"
    ManagedBy = "Terraform"
  })
}
```

## Reference Guide

| Topic | Reference | Load When |
|-------|-----------|-----------|
| Module Inventory | [module-inventory.md](references/module-inventory.md) | Need to know which modules exist and how to use them |
| AWS Patterns | [aws-patterns.md](references/aws-patterns.md) | ECS, RDS, CloudFront, ALB, WAF specifics |
| State & Backend | [state-and-backend.md](references/state-and-backend.md) | State operations, backend config, migration |
| Naming & Tags | [naming-and-tags.md](references/naming-and-tags.md) | Resource naming, tagging strategy |
| Security Patterns | [security-patterns.md](references/security-patterns.md) | IAM, Secrets Manager, VPC endpoints, encryption |
| Deployment | [deployment-patterns.md](references/deployment-patterns.md) | Blue-green, CodeDeploy, ECS, EventBridge |
| Tooling | [tooling.md](references/tooling.md) | tflint, Checkov, terraform-docs, Infracost, pre-commit |

## Constraints

### MUST DO
- Pin provider versions with `>=` constraints and set `required_version`
- Use S3 backend with `use_lockfile = true` for all shared environments
- Add `validation` blocks to variables with constrained values
- Add `description` to every variable and output
- Use `for_each` over `count` unless ordering matters
- Use `merge(var.tags, {...})` for consistent tagging
- Use `create_before_destroy = true` for zero-downtime replacements
- Use `data.aws_iam_policy_document` for IAM policies
- Run full validation chain before planning

### MUST NOT DO
- Hardcode AWS credentials, account IDs, or regions in `.tf` files
- Use local state for production or shared environments
- Run `terraform apply -auto-approve` in production
- Commit `.terraform/` directories or `.tfstate` files
- Store secrets in `.tfvars` or variable defaults
- Mix provider versions without version constraints
- Create circular module dependencies
- Skip input validation on user-facing variables
