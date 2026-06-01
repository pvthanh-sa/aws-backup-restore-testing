# State & Backend Management

## S3 Backend Configuration

### Standard Backend Pattern
```hcl
terraform {
  backend "s3" {
    bucket       = "<project>-tfstate-storage"
    region       = "ap-northeast-1"
    key          = "<environment>/terraform.tfstate"
    profile      = "<aws-profile-with-mfa>"
    use_lockfile = true
  }
}
```

### Key Principles
- **One state file per environment** — separate `key` paths (e.g., `tokyo-dev/terraform.tfstate`, `tokyo-staging/terraform.tfstate`)
- **Always enable locking** — use `use_lockfile = true` (native S3 locking, no DynamoDB needed for Terraform >= 1.10)
- **Legacy locking** — for Terraform < 1.10, use `dynamodb_table` for state locking
- **Profile-based auth** — use MFA-protected AWS profiles via `shared_credentials_files`
- **Never use local state** for production or shared environments

### Backend Migration
```bash
# Move from local to S3
terraform init -migrate-state

# Move between S3 backends
terraform init -migrate-state -backend-config="bucket=new-bucket"

# Reconfigure backend (discard old state)
terraform init -reconfigure
```

## State Operations

### Import Existing Resources
```bash
# Import a single resource
terraform import aws_s3_bucket.this my-bucket-name

# Import into a module
terraform import module.network.aws_vpc.this vpc-0123456789abcdef0

# Import with for_each key
terraform import 'aws_security_group_rule.db_from_sg["sg-abc123"]' sgr-0123456789abcdef0
```

### Move Resources
```bash
# Rename a resource (no re-creation)
terraform state mv aws_s3_bucket.old aws_s3_bucket.new

# Move into a module
terraform state mv aws_vpc.this module.network.aws_vpc.this

# Move between modules
terraform state mv module.old.aws_rds_cluster.this module.new.aws_rds_cluster.this
```

### Remove from State (without destroying)
```bash
# Remove resource from state (resource stays in AWS)
terraform state rm aws_s3_bucket.old

# Remove entire module from state
terraform state rm module.deprecated
```

### Inspect State
```bash
# List all resources in state
terraform state list

# Show specific resource details
terraform state show aws_ecs_service.this

# Pull state to local file (for inspection)
terraform state pull > state.json

# Push local state back (dangerous — use with caution)
terraform state push state.json
```

## Workspace Patterns

### When to Use Workspaces
- Multiple instances of the **same** infrastructure (e.g., dev/staging/prod with identical modules)
- **Not recommended** when environments differ significantly in resources or configuration

### Workspace Commands
```bash
terraform workspace new staging
terraform workspace select staging
terraform workspace list
terraform workspace show        # Current workspace
terraform workspace delete old-workspace
```

### Workspace in Code
```hcl
locals {
  env = terraform.workspace

  config = {
    dev     = { instance_type = "t3.small",  min_capacity = 1 }
    staging = { instance_type = "t3.medium", min_capacity = 2 }
    prod    = { instance_type = "t3.large",  min_capacity = 3 }
  }
}

resource "aws_ecs_service" "this" {
  desired_count = local.config[local.env].min_capacity
}
```

## State Troubleshooting

### State Lock Issues
```bash
# Force unlock (only if you're certain no one else is running)
terraform force-unlock <LOCK_ID>
```

### State Drift
```bash
# Detect drift (plan shows changes you didn't make)
terraform plan

# Reconcile state with actual infrastructure
terraform refresh    # deprecated — use terraform apply -refresh-only

# Better approach: refresh-only plan
terraform plan -refresh-only
terraform apply -refresh-only
```

### Corrupted State
```bash
# Pull current state
terraform state pull > backup.json

# Edit state JSON (fix issues)
# Then push back
terraform state push backup.json
```

## Best Practices

1. **Always backup state** before manual operations: `terraform state pull > backup-$(date +%Y%m%d).json`
2. **Use `terraform plan` after state operations** to verify no unintended changes
3. **Never edit state JSON directly** unless absolutely necessary — use `terraform state mv/rm/import`
4. **Enable versioning on the S3 state bucket** for state history and recovery
5. **Restrict S3 bucket access** to only Terraform operators and CI/CD roles
6. **Use separate state files** for independent infrastructure components (network vs app vs monitoring)
7. **Tag state resources** for easy identification: `Terraform = true, ManagedBy = Terraform`
