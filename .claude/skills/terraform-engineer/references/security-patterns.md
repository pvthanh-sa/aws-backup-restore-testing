# Security Patterns

## Secrets Management

### RDS Credentials with Secrets Manager
```hcl
# Generate random password
resource "random_password" "rds" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Store in Secrets Manager
resource "aws_secretsmanager_secret" "rds_credentials" {
  name = "${var.app_name}-rds-credentials"
  tags = merge(var.tags, { Name = "${var.app_name}-rds-credentials" })
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.rds.result
    host     = aws_rds_cluster.this.endpoint
    port     = aws_rds_cluster.this.port
    dbname   = var.database_name
  })
}

# Reference in RDS
resource "aws_rds_cluster" "this" {
  master_username = var.master_username
  master_password = random_password.rds.result

  lifecycle {
    ignore_changes = [master_password]  # Managed by rotation
  }
}
```

### Automatic Password Rotation
```hcl
resource "aws_secretsmanager_secret_rotation" "rds" {
  secret_id           = aws_secretsmanager_secret.rds_credentials.id
  rotation_lambda_arn = aws_lambda_function.rotation.arn

  rotation_rules {
    automatically_after_days = 30
  }
}
```

## IAM Patterns

### IAM Policy Document (Data Source)
Always use `data.aws_iam_policy_document` instead of inline JSON:
```hcl
data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.app_name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}
```

### Reusable IAM Role Module
```hcl
module "ecs_task_role" {
  source = "../../modules/iam_role"

  app_name           = var.app_name
  role_name_suffix   = "ecs-task-role"
  service_principals = ["ecs-tasks.amazonaws.com"]
  policy_arns_map    = {
    secrets   = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
    s3_access = aws_iam_policy.s3_access.arn
  }
  tags = var.tags
}
```

### Least-Privilege IAM for ECS
```hcl
data "aws_iam_policy_document" "ecs_task_execution" {
  # ECR pull
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:GetAuthorizationToken"
    ]
    resources = ["*"]
  }

  # CloudWatch Logs
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  # Secrets Manager (specific secrets only)
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.rds_credentials.arn]
  }
}
```

### GitHub Actions OIDC
```hcl
# OIDC Provider
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"]
}

# Trust Policy for GitHub Actions
data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}
```

## Network Security

### VPC Endpoints (Private Access to AWS Services)
```hcl
# Gateway endpoint (S3, DynamoDB) — free
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.this.id
  service_name = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
}

# Interface endpoint (Secrets Manager, ECR, etc.) — costs per hour
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}
```

### Security Group Externalization
Pattern: Define security group in the module, allow external rules via variable:
```hcl
# Module creates the SG
resource "aws_security_group" "this" {
  name_prefix = "${var.app_name}-ecs-"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.app_name}-ecs-sg" })
}

# Output SG ID for external rule attachment
output "security_group_id" {
  value = aws_security_group.this.id
}

# External rules via for_each
resource "aws_security_group_rule" "ingress" {
  for_each = var.allowed_security_groups

  security_group_id        = aws_security_group.this.id
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  source_security_group_id = each.value
}
```

## Encryption Patterns

### S3 Encryption
```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"  # or "aws:kms" for KMS
    }
    bucket_key_enabled = true
  }
}
```

### RDS Encryption
```hcl
resource "aws_rds_cluster" "this" {
  storage_encrypted = true
  kms_key_id        = var.kms_key_id  # null = AWS-managed key
}
```

### EBS Encryption
```hcl
resource "aws_ebs_default_encryption" "this" {
  enabled = true
}
```

## WAF Security
```hcl
module "waf" {
  source = "../../modules/waf_standard"

  app_name     = var.app_name
  service_type = "alb"  # Presets: cloudfront, alb, api_gateway, appsync, cognito, apprunner
  resource_arn = module.alb.alb_arn
  tags         = var.tags
}
```

## Security Checklist

When reviewing Terraform code, verify:
- [ ] No hardcoded credentials, account IDs, or secrets
- [ ] S3 buckets have encryption and versioning enabled
- [ ] S3 buckets block public access (unless frontend hosting)
- [ ] RDS encryption enabled, credentials in Secrets Manager
- [ ] Security groups are restrictive (no 0.0.0.0/0 for SSH)
- [ ] IAM policies follow least privilege
- [ ] VPC endpoints used for private subnet AWS access
- [ ] WAF attached to public-facing resources
- [ ] Sensitive outputs marked `sensitive = true`
- [ ] State file encrypted in S3 with restricted access
