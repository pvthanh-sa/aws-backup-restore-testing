# AWS Infrastructure Patterns

## 1. ECS Fargate + CodeDeploy Blue-Green

### Task Definition with Fargate
```hcl
resource "aws_ecs_task_definition" "this" {
  family                   = var.app_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = templatefile(
    "${path.module}/container_definitions/server-task-def.json.tpl",
    {
      container_name = var.container_names[0]
      container_port = var.container_port
      app_name       = var.app_name
      aws_region     = var.region
      ecr_image_uri  = var.ecr_image_uri
    }
  )

  tags = merge(var.tags, { Name = "${var.app_name}-task-def" })
}
```

### Blue-Green Target Groups
```hcl
resource "random_uuid" "tg_blue" {}
resource "random_uuid" "tg_green" {}

resource "aws_lb_target_group" "blue" {
  name        = "tg-${substr(random_uuid.tg_blue.result, 0, 26)}"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}

resource "aws_lb_target_group" "green" {
  name        = "tg-${substr(random_uuid.tg_green.result, 0, 26)}"
  # ... same configuration as blue
}
```

### ECS Service with CodeDeploy Controller
```hcl
resource "aws_ecs_service" "this" {
  name            = "${var.app_name}-service"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.subnet_ids
    security_groups = [aws_security_group.ecs.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = var.container_names[0]
    container_port   = var.container_port
  }

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  # CodeDeploy manages these — ignore Terraform drift
  lifecycle {
    ignore_changes = [load_balancer, task_definition]
  }
}
```

## 2. ALB vs NLB

### Conditional Load Balancer Type
```hcl
variable "load_balancer_type" {
  type = string
  validation {
    condition     = contains(["alb", "nlb"], var.load_balancer_type)
    error_message = "Must be 'alb' or 'nlb'."
  }
}

resource "aws_lb" "this" {
  name               = "${var.app_name}-${var.load_balancer_type}"
  internal           = var.internal
  load_balancer_type = var.load_balancer_type == "alb" ? "application" : "network"
  security_groups    = var.load_balancer_type == "alb" ? [aws_security_group.lb[0].id] : null
  subnets            = var.subnet_ids
}
```

### ALB with CloudFront Prefix List
```hcl
dynamic "ingress" {
  for_each = var.allow_cloudfront_prefix_list ? [1] : []
  content {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront[0].id]
    description     = "HTTPS from CloudFront"
  }
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.allow_cloudfront_prefix_list ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}
```

## 3. CloudFront + S3 Frontend

### Origin Access Control
```hcl
resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${var.app_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3Origin"
    # ...
  }
}
```

### CloudFront Functions for SPA Routing
```javascript
// Rewrites /path → /path/index.html for SPA client-side routing
function handler(event) {
  var request = event.request;
  var uri = request.uri;

  if (uri.endsWith('/')) {
    request.uri += 'index.html';
  } else if (!uri.includes('.')) {
    request.uri += '/index.html';
  }

  return request;
}
```

### ACM for CloudFront (must be us-east-1)
```hcl
# CloudFront requires certificate in us-east-1
resource "aws_acm_certificate" "cloudfront" {
  provider          = aws.virginia  # us-east-1 alias
  domain_name       = var.domain_name
  validation_method = "DNS"

  subject_alternative_names = var.subject_alternative_names

  lifecycle {
    create_before_destroy = true
  }
}
```

## 4. WAF Service Type Presets

```hcl
locals {
  presets = {
    cloudfront = {
      scope       = "CLOUDFRONT"
      rate_limit  = 2000
      managed_rules = ["AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet"]
    }
    alb = {
      scope       = "REGIONAL"
      rate_limit  = 1000
      managed_rules = ["AWSManagedRulesCommonRuleSet", "AWSManagedRulesSQLiRuleSet"]
    }
    api_gateway = {
      scope       = "REGIONAL"
      rate_limit  = 500
      managed_rules = ["AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet"]
    }
  }
  
  preset = local.presets[var.service_type]
  effective_rate_limit = coalesce(var.rate_limit_override, local.preset.rate_limit)
}
```

## 5. Aurora/RDS Patterns

### Aurora Cluster with Global Database Support
```hcl
resource "aws_rds_cluster" "this" {
  cluster_identifier = "${var.app_name}-rds"
  engine             = var.engine          # "aurora-postgresql" or "aurora-mysql"
  engine_version     = var.engine_version  # "16.4"
  database_name      = var.setup_as_secondary ? null : var.database_name
  master_username    = var.setup_as_secondary ? null : var.master_username
  master_password    = var.setup_as_secondary ? null : random_password.rds[0].result

  global_cluster_identifier = var.setup_globaldb ? aws_rds_global_cluster.this[0].id : null

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  storage_encrypted      = true

  tags = merge(var.tags, { Name = "${var.app_name}-rds" })
}
```

### Security Group with for_each
```hcl
resource "aws_security_group_rule" "db_from_sg" {
  for_each = var.allowed_security_groups

  security_group_id        = aws_security_group.rds.id
  type                     = "ingress"
  from_port                = aws_rds_cluster.this.port
  to_port                  = aws_rds_cluster.this.port
  protocol                 = "tcp"
  source_security_group_id = each.value
  description              = "Access from ${each.key}"
}
```

## 6. VPC & Networking

### Multi-AZ Subnet Pattern
```hcl
locals {
  azs = [for az in var.azs_name : "${var.aws_region}${az}"]
  
  nat_gateway_count = var.single_nat_gateway ? 1 : (
    var.one_nat_gateway_per_az ? length(var.azs) : length(var.private_subnets)
  )
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.app_name}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}
```

### VPC Endpoints
```hcl
# Gateway endpoint — free (S3, DynamoDB)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
}

# Interface endpoint — per-hour cost (Secrets Manager, ECR, etc.)
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}
```

## 7. ElastiCache

### Serverless with Valkey
```hcl
resource "aws_elasticache_serverless_cache" "this" {
  engine = "valkey"
  name   = "${var.app_name}-cache"

  subnet_ids         = var.subnet_ids
  security_group_ids = [aws_security_group.cache.id]

  daily_snapshot_time      = "09:00"
  snapshot_retention_limit = var.snapshot_retention_limit

  tags = merge(var.tags, { Name = "${var.app_name}-cache" })
}
```

## 8. Dynamic Blocks & Conditional Resources

### Dynamic Block Pattern
```hcl
dynamic "ingress" {
  for_each = var.additional_ingress_rules
  content {
    from_port       = ingress.value.from_port
    to_port         = ingress.value.to_port
    protocol        = ingress.value.protocol
    cidr_blocks     = ingress.value.cidr_blocks
    description     = ingress.value.description
  }
}
```

### Conditional Resource with count
```hcl
resource "aws_acm_certificate" "this" {
  count             = var.create_certificate ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }
}

# Reference conditional resource
output "certificate_arn" {
  value = var.create_certificate ? aws_acm_certificate.this[0].arn : null
}
```

### Variable Validation
```hcl
variable "monitoring_interval" {
  type        = number
  description = "Enhanced monitoring interval in seconds"
  default     = 60
  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "Valid values: 0, 1, 5, 10, 15, 30, 60."
  }
}
```
