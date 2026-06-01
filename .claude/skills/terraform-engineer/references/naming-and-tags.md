# Naming & Tagging Conventions

## Resource Naming

### Standard Pattern
```
${var.app_name}-<resource-type>[-<qualifier>]
```

### Examples
| Resource | Name Pattern | Example |
|----------|-------------|---------|
| VPC | `${var.app_name}-vpc` | `myapp-staging-vpc` |
| Subnet | `${var.app_name}-<tier>-<az>` | `myapp-staging-private-1a` |
| Security Group | `${var.app_name}-<service>-sg` | `myapp-staging-ecs-sg` |
| ALB | `${var.app_name}-alb` | `myapp-staging-alb` |
| Target Group | `${var.app_name}-tg-<color>` | `myapp-staging-tg-blue` |
| ECS Cluster | `${var.app_name}` | `myapp-staging` |
| ECS Service | `${var.app_name}-service` | `myapp-staging-service` |
| ECS Task Def | `${var.app_name}` | `myapp-staging` |
| RDS Cluster | `${var.app_name}-rds` | `myapp-staging-rds` |
| S3 Bucket | `${var.app_name}-<purpose>-<random>` | `myapp-staging-frontend-a1b2` |
| IAM Role | `${var.app_name}-<purpose>-role` | `myapp-staging-ecs-task-role` |
| IAM Policy | `${var.app_name}-<purpose>-policy` | `myapp-staging-ecs-task-policy` |
| ECR Repo | `${var.app_name}` | `myapp-staging` |
| CloudFront | `${var.app_name}-cdn` | `myapp-staging-cdn` |
| WAF ACL | `${var.app_name}-waf` | `myapp-staging-waf` |
| Secrets Manager | `${var.app_name}-<secret-type>` | `myapp-staging-rds-credentials` |
| CodeDeploy App | `${var.app_name}` | `myapp-staging` |
| CodeDeploy DG | `${var.app_name}-dg` | `myapp-staging-dg` |

### S3 Bucket Uniqueness
S3 bucket names must be globally unique. Use `random_uuid`:
```hcl
resource "random_uuid" "bucket" {}

resource "aws_s3_bucket" "this" {
  bucket = "${var.app_name}-storage-${substr(random_uuid.bucket.result, 0, 3)}"
}
```

### Variable Naming
| Convention | Examples |
|-----------|----------|
| Boolean create flags | `create_certificate`, `create_dns_record` |
| Boolean enable flags | `enable_monitoring`, `enable_encryption` |
| ARN references | `vpc_id`, `subnet_ids`, `role_arn`, `arn_suffix` |
| List variables | Plural form: `subnet_ids`, `security_group_ids`, `container_names` |
| Map variables | `tags`, `environment_variables`, `allowed_security_groups` |

## Tagging Strategy

### Standard Tag Pattern
```hcl
tags = merge(
  var.tags,
  {
    Name      = "${var.app_name}-<resource-description>"
    ManagedBy = "Terraform"
  }
)
```

### Common Tags (defined in environment locals)
```hcl
# environments/<env>/locals.tf
locals {
  tags = {
    Project     = "my-project"
    Environment = var.environment    # develop, staging, production
    ManagedBy   = "Terraform"
    Team        = "devops"
  }
}
```

### Passing Tags to Modules
```hcl
# environments/<env>/main.tf
module "network" {
  source = "../../modules/network"
  
  app_name = var.app_name
  tags     = local.tags
  # ...
}
```

### Tags in Modules
```hcl
# modules/<module>/main.tf
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  
  tags = merge(var.tags, {
    Name = "${var.app_name}-vpc"
  })
}

resource "aws_subnet" "private" {
  for_each = toset(var.private_subnets)
  
  vpc_id     = aws_vpc.this.id
  cidr_block = each.value
  
  tags = merge(var.tags, {
    Name = "${var.app_name}-private-${each.key}"
    Tier = "private"
  })
}
```

### Required Tags for Cost Allocation
- `Project` — for cost allocation and billing
- `Environment` — develop/staging/production
- `ManagedBy` — always "Terraform"
- `Team` — owning team

### AWS Cost Allocation Tags
Enable these tags in AWS Billing Console for cost tracking:
```hcl
resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
}
```

## Environment Naming

### PREFIX Convention
| Environment | Prefix | Branch | Example Resource |
|------------|--------|--------|------------------|
| Development | `dev` | `develop` | `dev-myapp-ecs-cluster` |
| Demo | `demo` | `demo` | `demo-myapp-ecs-cluster` |
| Staging | `stg` | `staging` | `stg-myapp-ecs-cluster` |
| Production | `prod` | `main`/tag | `prod-myapp-ecs-cluster` |

### Using PREFIX in Terraform
```hcl
variable "environment" {
  description = "Environment name"
  type        = string
  validation {
    condition     = contains(["develop", "demo", "staging", "production"], var.environment)
    error_message = "Must be: develop, demo, staging, or production."
  }
}

locals {
  prefix = {
    develop    = "dev"
    demo       = "demo"
    staging    = "stg"
    production = "prod"
  }
  env_prefix = local.prefix[var.environment]
  app_name   = "${local.env_prefix}-${var.project_name}"
}
```
